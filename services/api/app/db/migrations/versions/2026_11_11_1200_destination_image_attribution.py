"""Add destination photo attribution columns.

Revision ID: 2026_11_11_1200
Revises: 2026_11_11_1000

Restored on 2026-11-15. This revision was applied to the Neon database from an
earlier working copy, but its file was missing from the repository, which made
`alembic upgrade` fail with "Can't locate revision". The columns below match
the live schema exactly (all nullable, no indexes or constraints):
image_public_id varchar(255), image_credit varchar(500),
image_license varchar(100), image_source_url text.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_11_1200"
down_revision: str | Sequence[str] | None = "2026_11_11_1000"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column("destinations", sa.Column("image_public_id", sa.String(255), nullable=True))
    op.add_column("destinations", sa.Column("image_credit", sa.String(500), nullable=True))
    op.add_column("destinations", sa.Column("image_license", sa.String(100), nullable=True))
    op.add_column("destinations", sa.Column("image_source_url", sa.Text(), nullable=True))


def downgrade() -> None:
    op.drop_column("destinations", "image_source_url")
    op.drop_column("destinations", "image_license")
    op.drop_column("destinations", "image_credit")
    op.drop_column("destinations", "image_public_id")
