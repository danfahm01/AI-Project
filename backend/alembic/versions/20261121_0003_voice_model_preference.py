"""voice model preference

Revision ID: 0003
Revises: 0002
Create Date: 2026-11-21 09:00:00.000000

"""
from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op


# revision identifiers, used by Alembic.
revision: str = '0003'
down_revision: str | None = '0002'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    with op.batch_alter_table('user_preferences', schema=None) as batch_op:
        batch_op.add_column(sa.Column('voice_provider', sa.String(length=50), nullable=True))
        batch_op.add_column(sa.Column('voice_model', sa.String(length=100), nullable=True))


def downgrade() -> None:
    with op.batch_alter_table('user_preferences', schema=None) as batch_op:
        batch_op.drop_column('voice_model')
        batch_op.drop_column('voice_provider')
