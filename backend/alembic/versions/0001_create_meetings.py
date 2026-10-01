"""create meetings table

Revision ID: 0001
Revises:
Create Date: 2026-10-01
"""

import sqlalchemy as sa

from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_table(
        "meetings",
        sa.Column("id", sa.Integer(), primary_key=True, autoincrement=True, nullable=False),
        sa.Column("title", sa.String(), nullable=False),
        sa.Column("starts_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("ends_at", sa.DateTime(timezone=True), nullable=False),
        sa.Column("attendee_count", sa.Integer(), nullable=False),
    )
    op.create_index("ix_meetings_id", "meetings", ["id"])


def downgrade() -> None:
    op.drop_index("ix_meetings_id", table_name="meetings")
    op.drop_table("meetings")
