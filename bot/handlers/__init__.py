from aiogram import Router

from . import common, tools


def setup() -> Router:
    root = Router()
    root.include_router(common.router)
    root.include_router(tools.router)
    return root
