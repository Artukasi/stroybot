"""Клиент kie.ai: загрузка файлов, генерация картинок (задачи + опрос), текстовая модель."""
import asyncio
import base64
import json
import logging

import aiohttp

from .config import config

log = logging.getLogger(__name__)

API = "https://api.kie.ai"
UPLOAD_API = "https://kieai.redpandaai.co"


class KieError(Exception):
    pass


def _headers() -> dict:
    return {"Authorization": f"Bearer {config.kie_api_key}", "Content-Type": "application/json"}


async def upload_image(data: bytes, filename: str = "photo.jpg") -> str:
    """Загружает картинку во временное хранилище kie.ai (живёт ~3 дня), возвращает URL."""
    return await upload_file(data, filename, "image/jpeg")


async def upload_file(data: bytes, filename: str, mime: str) -> str:
    """Загружает файл во временное хранилище kie.ai (живёт ~3 дня), возвращает URL."""
    payload = {
        "base64Data": f"data:{mime};base64," + base64.b64encode(data).decode(),
        "uploadPath": "stroybot",
        "fileName": filename,
    }
    async with aiohttp.ClientSession() as s:
        async with s.post(f"{UPLOAD_API}/api/file-base64-upload", json=payload, headers=_headers()) as r:
            body = await r.json(content_type=None)
    data_ = body.get("data") or {}
    url = data_.get("downloadUrl") or data_.get("fileUrl")
    if not body.get("success", body.get("code") == 200) or not url:
        raise KieError(f"upload failed: {body}")
    return url


async def create_task(model: str, input_: dict) -> str:
    async with aiohttp.ClientSession() as s:
        async with s.post(
            f"{API}/api/v1/jobs/createTask", json={"model": model, "input": input_}, headers=_headers()
        ) as r:
            body = await r.json(content_type=None)
    task_id = (body.get("data") or {}).get("taskId")
    if body.get("code") != 200 or not task_id:
        raise KieError(f"createTask failed: {body}")
    return task_id


async def wait_task_result(task_id: str, timeout: int = 600) -> dict:
    """Опрашивает задачу до готовности. Возвращает разобранный resultJson."""
    delay, waited = 3, 0
    async with aiohttp.ClientSession() as s:
        while waited < timeout:
            await asyncio.sleep(delay)
            waited += delay
            async with s.get(
                f"{API}/api/v1/jobs/recordInfo", params={"taskId": task_id}, headers=_headers()
            ) as r:
                body = await r.json(content_type=None)
            d = body.get("data") or {}
            state = d.get("state")
            if state == "success":
                raw = d.get("resultJson") or "{}"
                return json.loads(raw) if isinstance(raw, str) else raw
            if state == "fail":
                raise KieError(f"task failed: {d.get('failMsg') or d.get('failCode')}")
            delay = min(delay + 2, 10)
    raise KieError("timeout")


async def wait_task(task_id: str, timeout: int = 600) -> list[str]:
    """Опрашивает задачу до готовности. Возвращает список URL результатов."""
    result = await wait_task_result(task_id, timeout)
    urls = result.get("resultUrls") or []
    if not urls:
        raise KieError(f"no results: {result}")
    return urls


def find_text(obj) -> str:
    """Ищет распознанный текст в ответе STT: поле text на любом уровне вложенности."""
    if isinstance(obj, dict):
        if isinstance(obj.get("text"), str) and obj["text"].strip():
            return obj["text"]
        for v in obj.values():
            t = find_text(v)
            if t:
                return t
    elif isinstance(obj, list):
        for v in obj:
            t = find_text(v)
            if t:
                return t
    elif isinstance(obj, str) and obj.strip().startswith("{"):
        try:
            return find_text(json.loads(obj))
        except ValueError:
            return ""
    return ""


async def transcribe(audio: bytes, filename: str = "voice.ogg", mime: str = "audio/ogg") -> str:
    """Голос → текст через ElevenLabs Speech-to-Text на kie.ai."""
    url = await upload_file(audio, filename, mime)
    task_id = await create_task(config.stt_model, {"audio_url": url})
    result = await wait_task_result(task_id, timeout=180)
    text = find_text(result)
    if not text and result.get("resultUrls"):
        # некоторые модели кладут результат файлом
        async with aiohttp.ClientSession() as s:
            async with s.get(result["resultUrls"][0]) as r:
                body = await r.text()
        try:
            text = find_text(json.loads(body))
        except ValueError:
            text = body
    text = (text or "").strip()
    if not text:
        raise KieError(f"empty transcription: {str(result)[:300]}")
    return text


async def edit_image(image_url: str, prompt: str, aspect_ratio: str = "auto") -> list[str]:
    input_ = {"prompt": prompt, "image_urls": [image_url], "output_format": "png"}
    if aspect_ratio != "auto":
        input_["aspect_ratio"] = aspect_ratio
    task_id = await create_task(config.image_model, input_)
    return await wait_task(task_id)


async def generate_image(prompt: str, aspect_ratio: str = "4:3") -> list[str]:
    """Картинка по описанию, без исходного фото."""
    task_id = await create_task(config.t2i_model, {"prompt": prompt, "output_format": "png",
                                                   "image_size": aspect_ratio})
    return await wait_task(task_id)


def _extract_text(body: dict) -> str:
    """Поддерживает и OpenAI-формат (choices), и нативный формат Gemini (candidates)."""
    if body.get("choices"):
        msg = body["choices"][0].get("message") or {}
        content = msg.get("content")
        if isinstance(content, list):
            return "".join(p.get("text", "") for p in content if isinstance(p, dict))
        return content or ""
    if body.get("candidates"):
        parts = body["candidates"][0].get("content", {}).get("parts", [])
        return "".join(p.get("text", "") for p in parts if not p.get("thought"))
    raise KieError(f"unexpected chat response: {str(body)[:500]}")


async def chat(system: str, user_text: str, image_url: str | None = None, max_tokens: int = 2000) -> str:
    content: list[dict] = [{"type": "text", "text": user_text}]
    if image_url:
        content.append({"type": "image_url", "image_url": {"url": image_url}})
    payload = {
        "model": config.text_model,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": content},
        ],
        "stream": False,
        "max_tokens": max_tokens,
    }
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=180)) as s:
        async with s.post(f"{API}{config.text_model_path}", json=payload, headers=_headers()) as r:
            body = await r.json(content_type=None)
    if r.status != 200:
        raise KieError(f"chat http {r.status}: {str(body)[:500]}")
    text = _extract_text(body).strip()
    if not text:
        raise KieError("empty chat response")
    return text
