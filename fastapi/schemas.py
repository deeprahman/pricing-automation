from datetime import date, datetime
from decimal import Decimal
from typing import Any

from pydantic import BaseModel, EmailStr, Field, field_validator


class UserBase(BaseModel):
    email: EmailStr
    username: str = Field(min_length=3, max_length=100)
    full_name: str | None = Field(default=None, max_length=255)
    model_config = {"from_attributes": True}


class UserRegister(UserBase):
    password: str = Field(min_length=8, max_length=128)


class UserLogin(BaseModel):
    email: EmailStr
    password: str = Field(min_length=1, max_length=128)
    remember_me: bool = False


class UserResponse(UserBase):
    id: int
    is_active: bool
    is_admin: bool
    created_at: datetime
    updated_at: datetime | None = None


class TokenResponse(BaseModel):
    access_token: str
    token_type: str = "bearer"
    expires_in: int


class TokenData(BaseModel):
    user_id: int | None = None
    email: str | None = None


class TaskEnqueueCreate(BaseModel):
    queue_name: str = Field(min_length=1, max_length=100, pattern=r"^[a-z0-9_-]+$")
    worker_id: str = Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9_.:@/-]+$")
    action: str = Field(min_length=1, max_length=100, pattern=r"^[A-Za-z0-9_.:-]+$")
    payload: dict[str, Any] = Field(default_factory=dict)
    scheduled_at: datetime | None = None
    priority: int = Field(default=0, ge=0, le=100)
    max_attempts: int = Field(default=3, ge=1, le=10)

    @field_validator("queue_name", "worker_id", "action", mode="before")
    @classmethod
    def _normalize_task_enqueue_text(cls, value: str) -> str:
        normalized = str(value or "").strip()
        if not normalized:
            raise ValueError("Value cannot be blank")
        return normalized


class WorkerManagerCleanupRequest(BaseModel):
    before_date: date | None = None


class PricingRuleBase(BaseModel):
    property_id: int | None = None
    platform_id: int | None = None
    platform_property_lookup_id: int | None = None
    operation_code: str | None = None
    rule_config: dict[str, Any] | None = None
    applicable_dates: list[date] | None = None
    start_date: date | None = None
    end_date: date | None = None
    day_of_week_pattern: int | None = Field(default=None, ge=0, le=127)
    priority: int | None = Field(default=None, ge=0, le=100)
    rule_name: str | None = None
    status: str | None = None
    allow_override: bool | None = None
    requires_approval: bool | None = None


class PricingRuleCreate(PricingRuleBase):
    operation_code: str
    rule_config: dict[str, Any]


class PricingRuleUpdate(PricingRuleBase):
    pass


class PricingBulkDelete(BaseModel):
    property_id: int | None = None
    platform_id: int | None = None
    operation_codes: list[str] | None = None
    statuses: list[str] | None = None
    mode: str = Field(default="deactivate", pattern="^(deactivate|delete)$")


class PlatformPropertyImportItem(BaseModel):
    platform_property_id: str
    latitude: str
    longitude: str
    link_to_lookup_id: int | None = None
    name: str | None = None
    pms: str | None = None
    city: str | None = None
    state: str | None = None
    country: str | None = None
    timezone: str | None = None
    currency_code: str | None = None
    public_url: str | None = None
    raw: dict[str, Any] | None = None


class PlatformPropertyImportRequest(BaseModel):
    items: list[PlatformPropertyImportItem]


class PlatformPropertyLinkRequest(BaseModel):
    target_lookup_id: int


class SecretUpsert(BaseModel):
    secret: str
    description: str | None = None


class ApiTokenUpsert(BaseModel):
    secret: str
    validation_overrides: dict[str, str] = Field(default_factory=dict)


class LLMSettingsUpdate(BaseModel):
    selected_model: str = Field(min_length=1, max_length=200)
    timeout_seconds: int = Field(default=60, ge=1, le=600)
    enabled: bool = True
    allowed_models: list[str] | None = None

    @field_validator("selected_model", mode="before")
    @classmethod
    def _normalize_selected_model(cls, value: str) -> str:
        normalized = str(value or "").strip()
        if not normalized:
            raise ValueError("selected_model cannot be blank")
        return normalized

    @field_validator("allowed_models")
    @classmethod
    def _normalize_allowed_models(cls, value: list[str] | None) -> list[str] | None:
        if value is None:
            return None
        normalized: list[str] = []
        seen: set[str] = set()
        for item in value:
            model = str(item or "").strip()
            if not model or model in seen:
                continue
            if len(model) > 200:
                raise ValueError("allowed model names must be at most 200 characters")
            normalized.append(model)
            seen.add(model)
        return normalized


class LLMProviderHealthCheck(BaseModel):
    model: str = Field(min_length=1, max_length=200)
    timeout_seconds: int = Field(default=30, ge=1, le=600)
    api_key: str | None = None

    @field_validator("model", mode="before")
    @classmethod
    def _normalize_model(cls, value: str) -> str:
        normalized = str(value or "").strip()
        if not normalized:
            raise ValueError("model cannot be blank")
        return normalized

    @field_validator("api_key", mode="before")
    @classmethod
    def _normalize_api_key(cls, value: str | None) -> str | None:
        if value is None:
            return None
        normalized = str(value or "").strip()
        return normalized or None


class LLMModelPricingUpsert(BaseModel):
    input_price_per_1m_tokens: Decimal = Field(default=Decimal("0"), ge=0)
    output_price_per_1m_tokens: Decimal = Field(default=Decimal("0"), ge=0)
    currency: str = Field(default="USD", min_length=1, max_length=12)
    is_active: bool = True

    @field_validator("currency", mode="before")
    @classmethod
    def _normalize_currency(cls, value: str) -> str:
        normalized = str(value or "USD").strip().upper()
        if not normalized:
            raise ValueError("currency cannot be blank")
        return normalized


def _strip_non_empty_text(value: str | None) -> str | None:
    if value is None:
        return None
    normalized = value.strip()
    if not normalized:
        raise ValueError("Value cannot be blank")
    return normalized


class MessageClassCreate(BaseModel):
    name: str = Field(min_length=1, max_length=255)
    description: str = Field(min_length=1)
    is_active: bool = True

    @field_validator("name", "description")
    @classmethod
    def _normalize_text(cls, value: str) -> str:
        normalized = _strip_non_empty_text(value)
        return normalized or value


class MessageClassUpdate(BaseModel):
    name: str | None = Field(default=None, min_length=1, max_length=255)
    description: str | None = Field(default=None, min_length=1)
    is_active: bool | None = None

    @field_validator("name", "description")
    @classmethod
    def _normalize_optional_text(cls, value: str | None) -> str | None:
        return _strip_non_empty_text(value)
