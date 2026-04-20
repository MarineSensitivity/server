"""custom titiler app: default endpoints + msens cells factory."""
from titiler.application.main import app

from factory import MsensCellsFactory

msens = MsensCellsFactory()
app.include_router(msens.router, prefix="/msens", tags=["Marine Sensitivity"])
