"""OpenAI-backed message classifier for worker runtime flows."""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

try:
    from openai import OpenAI  # type: ignore
except Exception as exc:  # pragma: no cover - dependency/runtime guard
    OpenAI = None
    _openai_import_error = exc
else:
    _openai_import_error = None


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MODEL = "gpt-3.5-turbo"
DEFAULT_TIMEOUT_SECONDS = 60.0
REQUIRED_FALLBACK_CATEGORY = "unclassified"

SYSTEM_PROMPT_TEMPLATE = (
    "Classify into: {categories}. Return JSON with results[{{pk, class}}].\n\n"
    "Patterns:\n"
    "{patterns}\n\n"
    "Note: If no category matches, use '{fallback_category}' as the default class."
)


def _supports_custom_temperature(model_name: str) -> bool:
    normalized = model_name.strip().lower()
    # GPT-5 chat-completions variants currently accept only default temperature.
    return not normalized.startswith("gpt-5")


@dataclass
class LLMUsage:
    provider: str
    model: str
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    total_tokens: Optional[int] = None
    latency_ms: Optional[int] = None
    response_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)


class OpenAIClassificationError(RuntimeError):
    def __init__(
        self,
        message: str,
        *,
        error_code: str,
        retryable: bool,
        usage: Optional[LLMUsage] = None,
    ) -> None:
        super().__init__(message)
        self.error_code = error_code
        self.retryable = bool(retryable)
        self.usage = usage


class _NullLogSink:
    def info(self, *_args, **_kwargs) -> None:
        return None


def _parse_dotenv(path: Path) -> Dict[str, str]:
    env: Dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        env[key.strip()] = value.strip().strip('"').strip("'")
    return env


def _load_repo_env() -> Dict[str, str]:
    env: Dict[str, str] = {}
    for path in (ROOT / ".env", ROOT / ".env.prod", ROOT / ".env.local"):
        env.update(_parse_dotenv(path))
    env.update(os.environ)
    return env


def _as_optional_string(value: Any) -> Optional[str]:
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    text = str(value).strip()
    return text or None


def _coerce_optional_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _normalize_messages(messages: list[dict]) -> list[dict]:
    if not isinstance(messages, list) or not messages:
        raise ValueError("messages must be a non-empty list")

    normalized: list[dict] = []
    seen_pks: set[int] = set()
    for item in messages:
        if not isinstance(item, dict):
            raise ValueError("messages must contain objects")
        pk_raw = item.get("pk")
        body_raw = item.get("body")
        try:
            pk = int(pk_raw)
        except (TypeError, ValueError):
            raise ValueError(f"invalid pk value: {pk_raw!r}") from None
        body = _as_optional_string(body_raw)
        if body is None:
            raise ValueError(f"body is required for pk={pk}")
        if pk in seen_pks:
            raise ValueError(f"duplicate pk={pk}")
        seen_pks.add(pk)
        normalized.append({"pk": pk, "body": body})
    return normalized


def _normalize_categories(categories: list[str]) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for category in categories:
        value = _as_optional_string(category)
        if value is None:
            continue
        key = value.lower()
        if key in seen:
            continue
        seen.add(key)
        normalized.append(value)
    return normalized


def _normalize_category_descriptions(category_descriptions: Optional[Dict[str, str]]) -> Dict[str, str]:
    if not isinstance(category_descriptions, dict):
        return {}

    normalized: Dict[str, str] = {}
    for key, value in category_descriptions.items():
        category = _as_optional_string(key)
        description = _as_optional_string(value)
        if not category or not description:
            continue
        normalized[category.lower()] = description
    return normalized


def _build_patterns_block(
    categories: list[str],
    *,
    category_descriptions: Dict[str, str],
) -> str:
    lines: list[str] = []
    for category in categories:
        description = category_descriptions.get(category.lower())
        if description:
            lines.append(f"- {category}: {description}")
        else:
            lines.append(f"- {category}: Message category '{category}'.")
    return "\n".join(lines)


def _resolve_required_fallback_category(
    categories: list[str],
    *,
    required_name: str = REQUIRED_FALLBACK_CATEGORY,
) -> str:
    required_key = required_name.strip().lower()
    for category in categories:
        if category.strip().lower() == required_key:
            return category
    raise ValueError(
        f"allowed_categories must include required fallback category '{required_name}'"
    )


def _build_system_prompt(
    categories: list[str],
    *,
    category_descriptions: Dict[str, str],
) -> str:
    fallback_category = _resolve_required_fallback_category(categories)
    return SYSTEM_PROMPT_TEMPLATE.format(
        categories=", ".join(categories),
        patterns=_build_patterns_block(categories, category_descriptions=category_descriptions),
        fallback_category=fallback_category,
    )


def _category_from_row(row: dict) -> Optional[str]:
    direct = _as_optional_string(row.get("class")) or _as_optional_string(row.get("category"))
    if direct:
        return direct

    categories = row.get("categories")
    if not isinstance(categories, list) or not categories:
        return None

    best_category: Optional[str] = None
    best_confidence = float("-inf")
    for item in categories:
        if not isinstance(item, dict):
            continue
        category = _as_optional_string(item.get("category")) or _as_optional_string(item.get("class"))
        if not category:
            continue
        confidence_raw = item.get("confidence")
        try:
            confidence = float(confidence_raw)
        except (TypeError, ValueError):
            confidence = 0.0
        if best_category is None or confidence > best_confidence:
            best_category = category
            best_confidence = confidence
    return best_category


def _extract_results(payload: Any, expected_pks: list[int]) -> list[dict]:
    rows: list[Any]
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        rows = payload["results"]
    elif isinstance(payload, dict) and isinstance(payload.get("messages"), list):
        rows = payload["messages"]
    elif isinstance(payload, list):
        rows = payload
    else:
        raise ValueError("classifier response must contain a 'results' or 'messages' array")

    result_map: Dict[int, str] = {}
    for row in rows:
        if not isinstance(row, dict):
            continue
        pk_raw = row.get("pk")
        if pk_raw is None:
            pk_raw = row.get("message_id")
        try:
            pk = int(pk_raw)
        except (TypeError, ValueError):
            continue
        category = _category_from_row(row)
        if category is None:
            continue
        result_map[pk] = category

    expected_pk_set = set(expected_pks)
    missing = [pk for pk in expected_pks if pk not in result_map]
    if missing:
        raise ValueError(f"classifier response missing results for pk values: {missing}")

    extras = [pk for pk in result_map if pk not in expected_pk_set]
    if extras:
        raise ValueError(f"classifier response returned unexpected pk values: {sorted(extras)}")

    return [{"pk": pk, "class": result_map[pk]} for pk in expected_pks]


def _usage_from_response(response: Any, *, fallback_model: str, latency_ms: int) -> LLMUsage:
    usage_obj = getattr(response, "usage", None)
    usage = LLMUsage(
        provider="openai",
        model=_as_optional_string(getattr(response, "model", None)) or fallback_model,
        prompt_tokens=_coerce_optional_int(getattr(usage_obj, "prompt_tokens", None)),
        completion_tokens=_coerce_optional_int(getattr(usage_obj, "completion_tokens", None)),
        total_tokens=_coerce_optional_int(getattr(usage_obj, "total_tokens", None)),
        latency_ms=int(latency_ms),
        response_id=_as_optional_string(getattr(response, "id", None)),
    )
    finish_reason = None
    choices = getattr(response, "choices", None)
    if isinstance(choices, list) and choices:
        finish_reason = _as_optional_string(getattr(choices[0], "finish_reason", None))
    system_fingerprint = _as_optional_string(getattr(response, "system_fingerprint", None))
    if finish_reason:
        usage.metadata["finish_reason"] = finish_reason
    if system_fingerprint:
        usage.metadata["system_fingerprint"] = system_fingerprint
    return usage


class OpenAIMessageClassifier:
    """Classifies a batch of {pk, body} messages via OpenAI Chat Completions."""

    def __init__(
        self,
        *,
        api_key: Optional[str] = None,
        api_base_url: Optional[str] = None,
        model: Optional[str] = None,
        timeout_seconds: Optional[float] = None,
        category_descriptions: Optional[Dict[str, str]] = None,
        app_logger: Optional[Any] = None,
        app_log_kwargs: Optional[Dict[str, Any]] = None,
    ) -> None:
        if OpenAI is None:
            raise RuntimeError(
                "openai package is required for OpenAIMessageClassifier; install openai>=1.0,<2."
            ) from _openai_import_error

        env = _load_repo_env()

        resolved_api_key = _as_optional_string(api_key) or _as_optional_string(env.get("OPENAI_API_KEY"))
        if not resolved_api_key:
            raise ValueError("OPENAI_API_KEY is required for classify_messages")

        resolved_model = (
            _as_optional_string(model)
            or _as_optional_string(env.get("PWS_MESSAGE_CLASSIFIER_MODEL"))
            or _as_optional_string(env.get("OPENAI_LLM_MODEL"))
            or DEFAULT_MODEL
        )
        timeout_raw = timeout_seconds
        if timeout_raw is None:
            timeout_env = _as_optional_string(env.get("PWS_MESSAGE_CLASSIFIER_TIMEOUT_SECONDS"))
            if timeout_env is None:
                timeout_raw = DEFAULT_TIMEOUT_SECONDS
            else:
                timeout_raw = float(timeout_env)
        resolved_api_base_url = _as_optional_string(api_base_url) or _as_optional_string(env.get("OPENAI_API_BASE_URL"))
        if resolved_api_base_url:
            resolved_api_base_url = resolved_api_base_url.rstrip("/")
            if resolved_api_base_url == "https://api.openai.com":
                resolved_api_base_url = f"{resolved_api_base_url}/v1"

        self.model = str(resolved_model)
        self.timeout_seconds = float(timeout_raw)
        self.category_descriptions = _normalize_category_descriptions(category_descriptions)
        self.app_logger = app_logger or _NullLogSink()
        self.app_log_kwargs = dict(app_log_kwargs or {})
        client_kwargs: Dict[str, Any] = {"api_key": resolved_api_key, "timeout": self.timeout_seconds}
        if resolved_api_base_url:
            client_kwargs["base_url"] = resolved_api_base_url
        self.client = OpenAI(**client_kwargs)

    def classify_messages(self, messages: list[dict], *, allowed_categories: list[str]) -> tuple[list[dict], LLMUsage]:
        normalized_messages = _normalize_messages(messages)
        normalized_categories = _normalize_categories(allowed_categories)
        if not normalized_categories:
            raise ValueError("allowed_categories must be a non-empty list")
        fallback_category = _resolve_required_fallback_category(normalized_categories)

        category_definitions: list[Dict[str, str]] = []
        for category in normalized_categories:
            category_details: Dict[str, str] = {"name": category}
            description = self.category_descriptions.get(category.lower())
            if description:
                category_details["description"] = description
            category_definitions.append(category_details)
        expected_pks = [row["pk"] for row in normalized_messages]
        user_payload: Dict[str, Any] = {
            "allowed_categories": normalized_categories,
            "category_definitions": category_definitions,
            "messages": [{"pk": row["pk"], "message_body": row["body"]} for row in normalized_messages],
            "output_format": {
                "results": [
                    {"pk": "int", "class": "string (must be one of allowed_categories)"},
                ]
            },
        }
        user_payload["fallback_category"] = fallback_category

        system_content = _build_system_prompt(
            normalized_categories,
            category_descriptions=self.category_descriptions,
        )
        extra_rules = (
            "Return JSON only. Do not include markdown. "
            "Use only categories from allowed_categories. "
            "Return exactly one result for each input message with fields: pk, class."
        )
        system_content = f"{system_content}\n\n{extra_rules}".strip()
        self.app_logger.info(
            "OpenAI classifier system prompt created",
            metadata={
                "model": self.model,
                "allowed_categories": list(normalized_categories),
                "message_count": len(normalized_messages),
                "system_prompt": system_content,
            },
            **self.app_log_kwargs,
        )

        start_time = time.monotonic()
        try:
            request_payload: Dict[str, Any] = {
                "model": self.model,
                "response_format": {"type": "json_object"},
                "messages": [
                    {"role": "system", "content": system_content},
                    {"role": "user", "content": json.dumps(user_payload, ensure_ascii=True)},
                ],
            }
            if _supports_custom_temperature(self.model):
                request_payload["temperature"] = 0.1
            response = self.client.chat.completions.create(**request_payload)
        except Exception as exc:
            raise OpenAIClassificationError(
                f"openai classify request failed: {exc}",
                error_code="OPENAI_API_ERROR",
                retryable=True,
            ) from exc

        latency_ms = int((time.monotonic() - start_time) * 1000)
        usage = _usage_from_response(response, fallback_model=self.model, latency_ms=latency_ms)
        try:
            choices = getattr(response, "choices", None)
            if not isinstance(choices, list) or not choices:
                raise ValueError("response choices are empty")

            first_choice = choices[0]
            content = _as_optional_string(getattr(getattr(first_choice, "message", None), "content", None))
            if content is None:
                raise ValueError("response content is empty")

            payload = json.loads(content)
            results = _extract_results(payload, expected_pks)
        except Exception as exc:
            raise OpenAIClassificationError(
                f"invalid classifier response: {exc}",
                error_code="OPENAI_RESPONSE_INVALID",
                retryable=False,
                usage=usage,
            ) from exc

        return results, usage


__all__ = [
    "DEFAULT_MODEL",
    "LLMUsage",
    "OpenAIClassificationError",
    "OpenAIMessageClassifier",
    "REQUIRED_FALLBACK_CATEGORY",
]
