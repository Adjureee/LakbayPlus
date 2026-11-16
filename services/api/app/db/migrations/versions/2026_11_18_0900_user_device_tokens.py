"""Add user_device_tokens table for FCM push notifications.

Revision ID: 2026_11_18_0900
Revises: 2026_11_17_0900
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_18_0900"
down_revision: str | Sequence[str] | None = "2026_11_17_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "user_device_tokens",
        sa.Column("device_token_id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("user_id", sa.Integer(), nullable=False),
        sa.Column("platform", sa.String(length=20), nullable=False),
        sa.Column("device_token", sa.String(length=512), nullable=False),
        sa.Column(
            "is_active",
            sa.Boolean(),
            server_default=sa.text("true"),
            nullable=False,
        ),
        sa.Column(
            "created_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.Column(
            "updated_at",
            sa.DateTime(timezone=True),
            server_default=sa.text("now()"),
            nullable=False,
        ),
        sa.CheckConstraint(
            "platform IN ('android', 'ios', 'web')",
            name="ck_user_device_tokens_platform",
        ),
        sa.ForeignKeyConstraint(
            ["user_id"],
            ["users.user_id"],
            name="fk_user_device_tokens_user_id_users",
            ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("device_token_id", name="pk_user_device_tokens"),
        sa.UniqueConstraint(
            "user_id",
            "device_token",
            name="uq_user_device_tokens_user_token",
        ),
    )
    op.create_index(
        op.f("ix_user_device_tokens_device_token"),
        "user_device_tokens",
        ["device_token"],
        unique=False,
    )
    op.create_index(
        op.f("ix_user_device_tokens_user_id"),
        "user_device_tokens",
        ["user_id"],
        unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_user_device_tokens_user_id"), table_name="user_device_tokens")
    op.drop_index(op.f("ix_user_device_tokens_device_token"), table_name="user_device_tokens")
    op.drop_table("user_device_tokens")
