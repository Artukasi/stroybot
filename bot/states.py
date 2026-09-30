from aiogram.fsm.state import State, StatesGroup


class Flow(StatesGroup):
    design_photo = State()   # ждём фото комнаты
    design_style = State()   # ждём выбор стиля
    calc_input = State()     # ждём размеры для калькулятора
    estimate = State()       # ждём описание работ
    check_photo = State()    # ждём фото работы
    consult = State()        # диалог с консультантом
    kp = State()             # ждём описание объекта для КП


class Obj(StatesGroup):
    new_name = State()       # название нового объекта
    budget = State()         # бюджет объекта
    expense = State()        # сумма расхода
    stage = State()          # название этапа (+ срок)


class Report(StatesGroup):
    collecting = State()     # собираем фото и подписи
