from pydantic import BaseModel


class HealthResponse(BaseModel):
    status: str
    app_name: str
    environment: str
    api_prefix: str
    timezone: str
    # How replies about a place are checked against its records: enforce, log or off.
    claims_check_mode: str
