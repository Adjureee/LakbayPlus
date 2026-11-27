from io import StringIO

from alembic import command
from alembic.config import Config
from alembic.script import ScriptDirectory

from app.core.config import get_settings


def test_destination_media_migration_chain_and_ddl(monkeypatch) -> None:
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql+asyncpg://test:test@localhost/lakbay_test",
    )
    get_settings.cache_clear()
    config = Config("alembic.ini")
    script = ScriptDirectory.from_config(config)

    heads = script.get_heads()
    assert len(heads) == 1
    revisions = [item.revision for item in script.walk_revisions()]
    assert "2026_11_27_0415" in revisions
    assert "2026_11_27_0430" in revisions
    rev = script.get_revision("2026_11_27_0415")
    assert rev is not None
    assert rev.down_revision == "2026_11_25_0900"
    completed_rev = script.get_revision("2026_11_27_0430")
    assert completed_rev is not None
    assert completed_rev.down_revision == "2026_11_27_0415"

    upgrade_output = StringIO()
    config.output_buffer = upgrade_output
    command.upgrade(config, "head", sql=True)
    upgrade_sql = upgrade_output.getvalue()
    assert "media_url" in upgrade_sql
    assert "media_type" in upgrade_sql
    assert "media_public_id" in upgrade_sql
    assert "media_duration_seconds" in upgrade_sql
    assert "ck_destinations_media_type" in upgrade_sql
    assert "ck_destinations_media_duration" in upgrade_sql

    downgrade_output = StringIO()
    config.output_buffer = downgrade_output
    command.downgrade(config, "2026_11_27_0415:2026_11_25_0900", sql=True)
    downgrade_sql = downgrade_output.getvalue()
    assert "DROP CONSTRAINT ck_destinations_media_duration" in downgrade_sql
    assert "DROP CONSTRAINT ck_destinations_media_type" in downgrade_sql
    assert "DROP COLUMN media_url" in downgrade_sql
    get_settings.cache_clear()
