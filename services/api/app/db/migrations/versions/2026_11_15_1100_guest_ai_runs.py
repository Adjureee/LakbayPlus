"""Allow AI generation runs without a user, for signed-out guest chat.

Revision ID: 2026_11_15_1100
Revises: 2026_11_15_1000

Guest chat (POST /ai/chat/guest) records its runs with user_id NULL and
request_purpose 'guest_travel_chat'. Existing rows are unchanged.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_15_1100"
down_revision: str | Sequence[str] | None = "2026_11_15_1000"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.alter_column("ai_generation_runs", "user_id", existing_type=sa.Integer(), nullable=True)


def downgrade() -> None:
    op.execute("DELETE FROM ai_generation_runs WHERE user_id IS NULL")
    op.alter_column("ai_generation_runs", "user_id", existing_type=sa.Integer(), nullable=False)
