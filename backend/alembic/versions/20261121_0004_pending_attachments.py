"""pending attachments: uploads exist before their conversation is known

Revision ID: 0004
Revises: 0003
Create Date: 2026-11-21 12:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


# revision identifiers, used by Alembic.
revision: str = '0004'
down_revision: str | None = '0003'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table('conversation_attachments', schema=None) as batch_op:
        batch_op.alter_column('conversation_id', existing_type=sa.Uuid(), nullable=True)


def downgrade() -> None:
    # Pending uploads have no conversation; they cannot survive the downgrade.
    op.execute('DELETE FROM conversation_attachments WHERE conversation_id IS NULL')
    with op.batch_alter_table('conversation_attachments', schema=None) as batch_op:
        batch_op.alter_column('conversation_id', existing_type=sa.Uuid(), nullable=False)
