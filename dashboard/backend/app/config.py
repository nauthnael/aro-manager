from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    database_url: str
    secret_key: str
    dashboard_api_key: str
    admin_username: str = "admin"
    admin_password: str
    jwt_algorithm: str = "HS256"
    jwt_expire_hours: int = 24 * 7
    history_retention_days: int = 30
    stale_threshold_secs: int = 180  # node chưa báo cáo trong 3 phút = stale
    telegram_bot_token: str = ""

    class Config:
        env_file = ".env"


settings = Settings()
