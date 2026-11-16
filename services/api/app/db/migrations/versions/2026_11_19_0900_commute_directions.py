"""Commute directions: public-transport ways to reach a place, step by step.

Revision ID: 2026_11_19_0900
Revises: 2026_11_18_0900

Adds two tables and changes nothing that exists:

- commute_routes: one way to reach a destination (for example from "Davao City
  Proper"), with a source, a verified flag (who and when) and an active flag.
- commute_steps: the ordered steps of a route (jeepney, tricycle, habal-habal,
  van, bus, taxi, ferry, walk, or a fee), each with an optional "get off at"
  stop, minutes, fare and what the fare is for. Unknown values stay empty.

Downgrade drops both tables (and with them any commute data).
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_19_0900"
down_revision: str | Sequence[str] | None = "2026_11_18_0900"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        "commute_routes",
        sa.Column("commute_route_id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("destination_id", sa.Integer(), nullable=False),
        sa.Column("start_area", sa.String(length=255), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("source_url", sa.String(length=2048), nullable=True),
        sa.Column("is_verified", sa.Boolean(), server_default=sa.text("false"), nullable=False),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("verified_by_user_id", sa.Integer(), nullable=True),
        sa.Column("is_active", sa.Boolean(), server_default=sa.text("true"), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.text("now()"), nullable=False),
        sa.ForeignKeyConstraint(
            ["destination_id"], ["destinations.destination_id"],
            name="fk_commute_routes_destination_id_destinations", ondelete="CASCADE",
        ),
        sa.ForeignKeyConstraint(
            ["verified_by_user_id"], ["users.user_id"],
            name="fk_commute_routes_verified_by_user_id_users", ondelete="SET NULL",
        ),
        sa.PrimaryKeyConstraint("commute_route_id", name="pk_commute_routes"),
    )
    op.create_index(
        op.f("ix_commute_routes_commute_route_id"), "commute_routes", ["commute_route_id"], unique=False,
    )
    op.create_index(
        op.f("ix_commute_routes_destination_id"), "commute_routes", ["destination_id"], unique=False,
    )

    op.create_table(
        "commute_steps",
        sa.Column("commute_step_id", sa.Integer(), autoincrement=True, nullable=False),
        sa.Column("commute_route_id", sa.Integer(), nullable=False),
        sa.Column("step_order", sa.Integer(), nullable=False),
        sa.Column("vehicle", sa.String(length=20), nullable=False),
        sa.Column("from_place", sa.String(length=255), nullable=True),
        sa.Column("to_place", sa.String(length=255), nullable=True),
        sa.Column("get_off_at", sa.String(length=255), nullable=True),
        sa.Column("minutes", sa.Integer(), nullable=True),
        sa.Column("fare_php", sa.Numeric(precision=10, scale=2), nullable=True),
        sa.Column("charging_unit", sa.String(length=20), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.CheckConstraint("step_order >= 1", name="ck_commute_steps_order_positive"),
        sa.CheckConstraint(
            "vehicle IN ('jeepney', 'tricycle', 'habal_habal', 'van', 'bus', 'taxi', "
            "'ferry', 'walk', 'fee')",
            name="ck_commute_steps_vehicle",
        ),
        sa.CheckConstraint(
            "minutes IS NULL OR (minutes >= 0 AND minutes <= 1440)",
            name="ck_commute_steps_minutes_range",
        ),
        sa.CheckConstraint("fare_php IS NULL OR fare_php >= 0", name="ck_commute_steps_fare_non_negative"),
        sa.CheckConstraint(
            "charging_unit IS NULL OR charging_unit IN ('per_person', 'per_trip')",
            name="ck_commute_steps_charging_unit",
        ),
        sa.ForeignKeyConstraint(
            ["commute_route_id"], ["commute_routes.commute_route_id"],
            name="fk_commute_steps_commute_route_id_commute_routes", ondelete="CASCADE",
        ),
        sa.PrimaryKeyConstraint("commute_step_id", name="pk_commute_steps"),
        sa.UniqueConstraint("commute_route_id", "step_order", name="uq_commute_steps_route_order"),
    )
    op.create_index(
        op.f("ix_commute_steps_commute_route_id"), "commute_steps", ["commute_route_id"], unique=False,
    )


def downgrade() -> None:
    op.drop_index(op.f("ix_commute_steps_commute_route_id"), table_name="commute_steps")
    op.drop_table("commute_steps")
    op.drop_index(op.f("ix_commute_routes_destination_id"), table_name="commute_routes")
    op.drop_index(op.f("ix_commute_routes_commute_route_id"), table_name="commute_routes")
    op.drop_table("commute_routes")
