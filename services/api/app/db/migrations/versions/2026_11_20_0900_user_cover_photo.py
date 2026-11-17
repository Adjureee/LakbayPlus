"""Profile cover photo.

Revision ID: 2026_11_20_0900
Revises: 2026_11_19_0900

Adds one nullable column, users.cover_url, for the banner photo a traveler
chooses for their profile. Nothing that exists changes; empty means the app
shows its default banner.

Downgrade drops the column (and any cover photo addresses saved in it).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_20_0900"
down_revision: str | Sequence[str] | None = "2026_11_19_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("users", sa.Column("cover_url", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("users", "cover_url")
