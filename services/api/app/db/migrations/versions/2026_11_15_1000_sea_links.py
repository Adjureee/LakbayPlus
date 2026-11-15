"""Add piers, boat links and destination island groups for sea-aware routing.

Revision ID: 2026_11_15_1000
Revises: 2026_11_11_1000

Seeds starter Davao City <-> Samal and Talikud links. Their pier coordinates,
schedules and fares are approximate planning data: verified_at stays NULL and
route responses say so until an administrator verifies each row.
"""

from collections.abc import Sequence

from alembic import op
import sqlalchemy as sa


revision: str = "2026_11_15_1000"
down_revision: str | Sequence[str] | None = "2026_11_11_1000"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


STARTER_PORTS = [
    # (port_id, name, lat, lng, island_group, province, notes)
    (1, "Sasa RoRo Wharf (Davao City)", 7.1236, 125.6655, "mainland", "Davao City",
     "Vehicle barge terminal for Samal. Approximate gate location; verify."),
    (2, "Babak RoRo Landing (Samal)", 7.1180, 125.6880, "samal", "Davao del Norte",
     "Samal landing of the Sasa barge. Approximate location; verify."),
    (3, "Sta. Ana Wharf (Davao City)", 7.0760, 125.6260, "mainland", "Davao City",
     "Passenger boats to Talikud. Approximate location; verify."),
    (4, "Talikud Island Pier (Santa Cruz)", 6.9530, 125.6990, "talikud", "Davao del Norte",
     "Main Talikud landing. Approximate location; verify."),
]

STARTER_LINKS = [
    # (from, to, vessel, vehicles, crossing, wait, schedule)
    (1, 2, "roro_barge", True, 15, 20,
     "Frequent daytime trips; confirm first and last trips with the operator."),
    (3, 4, "passenger_ferry", False, 60, 45,
     "A few trips a day; confirm the schedule before travel."),
]


def upgrade() -> None:
    op.add_column("destinations", sa.Column("island_group", sa.String(50), nullable=True))
    op.create_index("ix_destinations_island_group", "destinations", ["island_group"])

    ports = op.create_table(
        "sea_ports",
        sa.Column("port_id", sa.Integer(), primary_key=True),
        sa.Column("name", sa.String(255), nullable=False, unique=True),
        sa.Column("lat", sa.Float(), nullable=False),
        sa.Column("lng", sa.Float(), nullable=False),
        sa.Column("island_group", sa.String(50), nullable=False),
        sa.Column("province", sa.String(255), nullable=True),
        sa.Column("notes", sa.Text(), nullable=True),
        sa.Column("source_url", sa.String(2048), nullable=True),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.CheckConstraint("lat >= -90 AND lat <= 90", name="ck_sea_ports_lat_range"),
        sa.CheckConstraint("lng >= -180 AND lng <= 180", name="ck_sea_ports_lng_range"),
    )
    op.create_index("ix_sea_ports_island_group", "sea_ports", ["island_group"])

    links = op.create_table(
        "sea_links",
        sa.Column("link_id", sa.Integer(), primary_key=True),
        sa.Column(
            "from_port_id", sa.Integer(),
            sa.ForeignKey("sea_ports.port_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column(
            "to_port_id", sa.Integer(),
            sa.ForeignKey("sea_ports.port_id", ondelete="CASCADE"), nullable=False,
        ),
        sa.Column("bidirectional", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("vessel_type", sa.String(30), nullable=False),
        sa.Column("allows_private_vehicle", sa.Boolean(), server_default=sa.false(), nullable=False),
        sa.Column("crossing_minutes", sa.Integer(), nullable=False),
        sa.Column("typical_wait_minutes", sa.Integer(), server_default="0", nullable=False),
        sa.Column("schedule_text", sa.String(500), nullable=True),
        sa.Column("fare_passenger", sa.Numeric(10, 2), nullable=True),
        sa.Column("fare_vehicle", sa.Numeric(10, 2), nullable=True),
        sa.Column("geometry_polyline", sa.Text(), nullable=True),
        sa.Column("source_url", sa.String(2048), nullable=True),
        sa.Column("verified_at", sa.DateTime(timezone=True), nullable=True),
        sa.Column("is_active", sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now()),
        sa.CheckConstraint("from_port_id <> to_port_id", name="ck_sea_links_distinct_ports"),
        sa.CheckConstraint("crossing_minutes > 0", name="ck_sea_links_crossing_positive"),
        sa.CheckConstraint("typical_wait_minutes >= 0", name="ck_sea_links_wait_non_negative"),
        sa.CheckConstraint(
            "vessel_type IN ('roro_barge', 'passenger_ferry', 'pump_boat')",
            name="ck_sea_links_vessel_type",
        ),
    )
    op.create_index("ix_sea_links_from_port_id", "sea_links", ["from_port_id"])
    op.create_index("ix_sea_links_to_port_id", "sea_links", ["to_port_id"])

    op.bulk_insert(ports, [
        {
            "port_id": port_id, "name": name, "lat": lat, "lng": lng,
            "island_group": group, "province": province, "notes": notes,
        }
        for port_id, name, lat, lng, group, province, notes in STARTER_PORTS
    ])
    op.bulk_insert(links, [
        {
            "from_port_id": from_id, "to_port_id": to_id, "vessel_type": vessel,
            "allows_private_vehicle": vehicles, "crossing_minutes": crossing,
            "typical_wait_minutes": wait, "schedule_text": schedule,
        }
        for from_id, to_id, vessel, vehicles, crossing, wait, schedule in STARTER_LINKS
    ])
    if op.get_bind().dialect.name == "postgresql":
        # Explicit IDs above do not advance the serial sequences.
        op.execute("SELECT setval('sea_ports_port_id_seq', (SELECT MAX(port_id) FROM sea_ports))")

    # Talikud is part of the Island Garden City of Samal, so tag it after Samal.
    op.execute(
        "UPDATE destinations SET island_group = 'samal' "
        "WHERE island_group IS NULL AND (location ILIKE '%Samal%' OR name ILIKE '%Samal%')"
    )
    op.execute(
        "UPDATE destinations SET island_group = 'talikud' "
        "WHERE location ILIKE '%Talikud%' OR name ILIKE '%Talikud%' OR name ILIKE '%Isla Reta%'"
    )
    op.execute(
        "UPDATE destinations SET island_group = 'balut' "
        "WHERE island_group IS NULL AND name ILIKE '%Balut Island%'"
    )


def downgrade() -> None:
    op.drop_index("ix_sea_links_to_port_id", table_name="sea_links")
    op.drop_index("ix_sea_links_from_port_id", table_name="sea_links")
    op.drop_table("sea_links")
    op.drop_index("ix_sea_ports_island_group", table_name="sea_ports")
    op.drop_table("sea_ports")
    op.drop_index("ix_destinations_island_group", table_name="destinations")
    op.drop_column("destinations", "island_group")
