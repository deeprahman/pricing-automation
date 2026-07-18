"""Ollama-backed message classifier for worker runtime flows."""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, Optional

try:
    import requests
except Exception as exc:  # pragma: no cover - dependency/runtime guard
    requests = None
    _requests_import_error = exc
else:
    _requests_import_error = None


ROOT = Path(__file__).resolve().parents[3]
DEFAULT_MODEL = "llama3.2:3b"
DEFAULT_OLLAMA_URL = "http://localhost:11550"
DEFAULT_TIMEOUT_SECONDS = 300.0  # Ollama can be slower than OpenAI
REQUIRED_FALLBACK_CATEGORY = "unclassified"

SYSTEM_PROMPT_TEMPLATE = (
    "Classify into: {categories}. Return ONLY valid JSON with top-level key \"results\".\n"
    "The value of \"results\" must be an array of objects shaped like {{\"pk\": 123, \"class\": \"category\"}}.\n"
    "Return exactly one result for each input message, preserve input order, and use only allowed categories.\n\n"
    "Patterns:\n"
    "{patterns}\n\n"
    "Note: If no category matches, use '{fallback_category}' as the default class.\n"
    "IMPORTANT: Return ONLY the JSON object, no other text, markdown, or explanations."
)


@dataclass
class LLMUsage:
    """Track LLM API usage metrics"""
    provider: str
    model: str
    prompt_tokens: Optional[int] = None
    completion_tokens: Optional[int] = None
    total_tokens: Optional[int] = None
    latency_ms: Optional[int] = None
    response_id: Optional[str] = None
    metadata: Dict[str, Any] = field(default_factory=dict)


class OllamaClassificationError(RuntimeError):
    """Error during Ollama classification"""
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
    """No-op logger"""
    def info(self, *_args, **_kwargs) -> None:
        return None


def _parse_dotenv(path: Path) -> Dict[str, str]:
    """Parse .env file"""
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
    """Load environment variables from .env files"""
    env: Dict[str, str] = {}
    for path in (ROOT / ".env", ROOT / ".env.prod", ROOT / ".env.local"):
        env.update(_parse_dotenv(path))
    env.update(os.environ)
    return env


def _as_optional_string(value: Any) -> Optional[str]:
    """Convert value to optional string"""
    if value is None:
        return None
    if isinstance(value, str):
        text = value.strip()
        return text or None
    text = str(value).strip()
    return text or None


def _coerce_optional_int(value: Any) -> Optional[int]:
    """Convert value to optional int"""
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _normalize_messages(messages: list[dict]) -> list[dict]:
    """Normalize and validate message list"""
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
    """Normalize and deduplicate categories"""
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
    """Normalize category descriptions"""
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
    """Build category patterns block for prompt"""
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
    """Resolve fallback category from allowed categories"""
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
    """Build system prompt for classification"""
    fallback_category = _resolve_required_fallback_category(categories)
    return SYSTEM_PROMPT_TEMPLATE.format(
        categories=", ".join(categories),
        patterns=_build_patterns_block(categories, category_descriptions=category_descriptions),
        fallback_category=fallback_category,
    )


def _category_from_row(row: dict) -> Optional[str]:
    """Extract category from result row"""
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
    """Extract results from classifier response"""
    rows: list[Any]
    if isinstance(payload, dict) and isinstance(payload.get("results"), list):
        rows = payload["results"]
    elif isinstance(payload, dict) and isinstance(payload.get("messages"), list):
        rows = payload["messages"]
    elif isinstance(payload, dict) and payload.get("pk") is not None:
        rows = [payload]
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


def _extract_json_from_response(text: str) -> dict:
    """Extract JSON object from Ollama response text"""
    # Try to find JSON object in the response
    json_pattern = r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}'
    
    matches = re.finditer(json_pattern, text, re.DOTALL)
    for match in matches:
        try:
            return json.loads(match.group())
        except json.JSONDecodeError:
            continue
    
    # If no match found, try to parse entire response
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        raise ValueError(f"could not extract valid JSON from response: {text[:200]}")


def _build_repair_user_payload(
    *,
    allowed_categories: list[str],
    expected_pks: list[int],
    previous_response: str,
) -> str:
    """Build follow-up instruction to repair malformed or incomplete model output."""
    payload = {
        "task": "Repair the previous classifier output so it matches the required schema.",
        "rules": [
            "Return ONLY a JSON object.",
            "Use a top-level key named results.",
            "results must be an array of objects with keys pk and class.",
            "Return exactly one result for each pk in required_pks.",
            "Preserve the required_pks order.",
            "class must be one of allowed_categories.",
        ],
        "allowed_categories": allowed_categories,
        "required_pks": expected_pks,
        "invalid_previous_response": previous_response,
        "required_output_example": {
            "results": [{"pk": expected_pks[0] if expected_pks else 1, "class": allowed_categories[0]}]
        },
    }
    return json.dumps(payload, ensure_ascii=True)


def _usage_from_ollama_response(
    latency_ms: int,
    *,
    model: str,
    response_text: str = "",
) -> LLMUsage:
    """Create LLMUsage from Ollama response"""
    # Ollama doesn't provide token counts in generation API
    return LLMUsage(
        provider="ollama",
        model=model,
        prompt_tokens=None,  # Ollama doesn't provide this
        completion_tokens=None,  # Ollama doesn't provide this
        total_tokens=None,  # Ollama doesn't provide this
        latency_ms=int(latency_ms),
        response_id=None,  # Ollama doesn't provide this
        metadata={
            "response_length": len(response_text),
        },
    )


class OllamaMessageClassifier:
    """Classifies a batch of {pk, body} messages via Ollama."""

    def __init__(
        self,
        *,
        api_url: Optional[str] = None,
        model: Optional[str] = None,
        timeout_seconds: Optional[float] = None,
        category_descriptions: Optional[Dict[str, str]] = None,
        app_logger: Optional[Any] = None,
        app_log_kwargs: Optional[Dict[str, Any]] = None,
    ) -> None:
        if requests is None:
            raise RuntimeError(
                "requests package is required for OllamaMessageClassifier; install requests>=2.28.0"
            ) from _requests_import_error

        env = _load_repo_env()

        resolved_api_url = (
            _as_optional_string(api_url)
            or _as_optional_string(env.get("OLLAMA_API_URL"))
            or _as_optional_string(env.get("OLLAMA_BASE_URL"))
            or DEFAULT_OLLAMA_URL
        )

        resolved_model = (
            _as_optional_string(model)
            or _as_optional_string(env.get("OLLAMA_MODEL"))
            or _as_optional_string(env.get("PWS_MESSAGE_CLASSIFIER_MODEL"))
            or DEFAULT_MODEL
        )

        timeout_raw = timeout_seconds
        if timeout_raw is None:
            timeout_env = _as_optional_string(env.get("OLLAMA_TIMEOUT_SECONDS"))
            if timeout_env is None:
                timeout_raw = DEFAULT_TIMEOUT_SECONDS
            else:
                timeout_raw = float(timeout_env)

        self.api_url = str(resolved_api_url).rstrip("/")
        self.model = str(resolved_model)
        self.timeout_seconds = float(timeout_raw)
        self.category_descriptions = _normalize_category_descriptions(category_descriptions)
        self.app_logger = app_logger or _NullLogSink()
        self.app_log_kwargs = dict(app_log_kwargs or {})
        
        # Verify Ollama is running
        self._verify_connection()

    def _verify_connection(self) -> None:
        """Verify connection to Ollama"""
        try:
            response = requests.get(
                f"{self.api_url}/api/tags",
                timeout=5.0,
            )
            response.raise_for_status()
        except Exception as exc:
            raise RuntimeError(
                f"Could not connect to Ollama at {self.api_url}. "
                "Make sure Ollama is running and the host port matches your Docker "
                "Compose mapping (current default: http://localhost:11550)."
            ) from exc

    def classify_messages(
        self,
        messages: list[dict],
        *,
        allowed_categories: list[str],
    ) -> tuple[list[dict], LLMUsage]:
        """
        Classify messages using Ollama.
        
        Args:
            messages: List of dicts with 'pk' (int) and 'body' (str)
            allowed_categories: List of category strings
            
        Returns:
            Tuple of (results list, LLMUsage)
            
        Raises:
            OllamaClassificationError: If classification fails
        """
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
            "messages": [
                {"pk": row["pk"], "message_body": row["body"]}
                for row in normalized_messages
            ],
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
            "Return ONLY valid JSON. Do not include markdown, code blocks, or any other text. "
            "Use only categories from allowed_categories. "
            "Return exactly one result for each input message with fields: pk, class."
        )
        system_content = f"{system_content}\n\n{extra_rules}".strip()

        self.app_logger.info(
            "Ollama classifier prompt created",
            metadata={
                "model": self.model,
                "api_url": self.api_url,
                "allowed_categories": list(normalized_categories),
                "message_count": len(normalized_messages),
            },
            **self.app_log_kwargs,
        )

        # Build messages for Ollama chat API
        messages_for_api = [
            {"role": "system", "content": system_content},
            {"role": "user", "content": json.dumps(user_payload, ensure_ascii=True)},
        ]

        response_content, latency_ms = self._send_chat_request(messages_for_api)
        try:
            payload = _extract_json_from_response(response_content)
            results = _extract_results(payload, expected_pks)
            usage = _usage_from_ollama_response(latency_ms, model=self.model, response_text=response_content)
        except Exception:
            repair_messages = [
                {"role": "system", "content": system_content},
                {"role": "user", "content": json.dumps(user_payload, ensure_ascii=True)},
                {"role": "assistant", "content": response_content},
                {
                    "role": "user",
                    "content": _build_repair_user_payload(
                        allowed_categories=normalized_categories,
                        expected_pks=expected_pks,
                        previous_response=response_content,
                    ),
                },
            ]
            repair_content, repair_latency_ms = self._send_chat_request(repair_messages)
            response_content = repair_content
            try:
                payload = _extract_json_from_response(repair_content)
                results = _extract_results(payload, expected_pks)
                usage = _usage_from_ollama_response(repair_latency_ms, model=self.model, response_text=repair_content)
            except json.JSONDecodeError as exc:
                usage = _usage_from_ollama_response(repair_latency_ms, model=self.model, response_text=repair_content)
                raise OllamaClassificationError(
                    f"invalid classifier response after repair attempt: {exc}",
                    error_code="OLLAMA_RESPONSE_INVALID",
                    retryable=False,
                    usage=usage,
                ) from exc
            except Exception as exc:
                usage = _usage_from_ollama_response(repair_latency_ms, model=self.model, response_text=repair_content)
                raise OllamaClassificationError(
                    f"invalid classifier response after repair attempt: {exc}",
                    error_code="OLLAMA_RESPONSE_INVALID",
                    retryable=False,
                    usage=usage,
                ) from exc

        return results, usage

    def _send_chat_request(self, messages_for_api: list[dict]) -> tuple[str, int]:
        """Send a chat request to Ollama and return the assistant content and latency."""
        start_time = time.monotonic()
        try:
            response = requests.post(
                f"{self.api_url}/api/chat",
                json={
                    "model": self.model,
                    "messages": messages_for_api,
                    "stream": False,
                    "format": "json",
                },
                timeout=self.timeout_seconds,
            )
            response.raise_for_status()
        except requests.exceptions.Timeout:
            raise OllamaClassificationError(
                f"ollama request timed out after {self.timeout_seconds}s",
                error_code="OLLAMA_TIMEOUT",
                retryable=True,
            ) from None
        except requests.exceptions.RequestException as exc:
            raise OllamaClassificationError(
                f"ollama classify request failed: {exc}",
                error_code="OLLAMA_API_ERROR",
                retryable=True,
            ) from exc

        _latency_ms = int((time.monotonic() - start_time) * 1000)
        try:
            response_json = response.json()
        except json.JSONDecodeError as exc:
            usage = _usage_from_ollama_response(_latency_ms, model=self.model)
            raise OllamaClassificationError(
                f"invalid ollama transport response: {exc}",
                error_code="OLLAMA_RESPONSE_INVALID",
                retryable=False,
                usage=usage,
            ) from exc

        response_content = _as_optional_string(response_json.get("message", {}).get("content"))
        if response_content is None:
            usage = _usage_from_ollama_response(_latency_ms, model=self.model)
            raise OllamaClassificationError(
                "invalid classifier response: response content is empty",
                error_code="OLLAMA_RESPONSE_INVALID",
                retryable=False,
                usage=usage,
            )
        return response_content, _latency_ms


__all__ = [
    "DEFAULT_MODEL",
    "DEFAULT_OLLAMA_URL",
    "LLMUsage",
    "OllamaClassificationError",
    "OllamaMessageClassifier",
    "REQUIRED_FALLBACK_CATEGORY",
]
