from workshop_common.server import run

from .main import admin_app, app, health

run(app, admin_app, health)
