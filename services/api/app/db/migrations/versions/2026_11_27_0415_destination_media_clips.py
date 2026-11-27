"""Add destination GIF and short video clip media fields.

Revision ID: 2026_11_27_0415
Revises: 2026_11_25_0900

Additive only: adds nullable media_url, media_type, media_public_id, and
media_duration_seconds columns plus check constraints on destinations.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_27_0415"
down_revision: str | Sequence[str] | None = "2026_11_25_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("destinations", sa.Column("media_url", sa.Text(), nullable=True))
    op.add_column(
        "destinations",
        sa.Column("media_type", sa.String(length=20), nullable=True),
    )
    op.add_column(
        "destinations",
        sa.Column("media_public_id", sa.String(length=255), nullable=True),
    )
    op.add_column(
        "destinations",
        sa.Column("media_duration_seconds", sa.Float(), nullable=True),
    )
    op.create_check_constraint(
        "ck_destinations_media_type",
        "destinations",
        "media_type IS NULL OR media_type IN ('image', 'gif', 'video')",
    )
    op.create_check_constraint(
        "ck_destinations_media_duration",
        "destinations",
        "media_duration_seconds IS NULL OR "
        "(media_duration_seconds >= 0 AND media_duration_seconds <= 15.0)",
    )


def downgrade() -> None:
    op.drop_constraint(
        "ck_destinations_media_duration",
        "destinations",
        type_="check",
    )
    op.drop_constraint(
        "ck_destinations_media_type",
        "destinations",
        type_="check",
    )
    op.drop_column("destinations", "media_duration_seconds")
    op.drop_column("destinations", "media_public_id")
    op.drop_column("destinations", "media_type")
    op.drop_column("destinations", "media_url")
