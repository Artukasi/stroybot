from aiogram import Router

from . import common, fallback, objects, report, tools


def setup() -> Router:
    root = Router()
    root.include_router(common.router)
    root.include_router(objects.router)   # до tools: команды /objects и /report важнее
    root.include_router(report.router)    # «ожидания фото/текста» в других сценариях
    root.include_router(tools.router)
    root.include_router(fallback.router)  # последним: ловит всё, что не подошло выше
    return root
