# Password Safe Admin Dashboard (FastAPI)

This service provides:

- `https://<domain>/pwsadmin` for JWT-based dashboard/auth pages
- `https://<domain>/pwsadmin/admin` for Starlette-Admin user management
- Read-only task access from `auto_pws`
- Writable auth/admin data in `admin_pws`

`/` remains n8n (handled by Nginx routing).
`/home` is not redirected by FastAPI or Nginx.

## 1. Required Environment

In your `.env` (or `.env.local`), set:

- `POSTGRES_USER`
- `POSTGRES_PASSWORD`
- `POSTGRES_DB` (n8n DB, usually `n8n`)
- `SCHEMA_DB` (usually `auto_pws`)
- `ADMIN_PWS_DB=admin_pws`
- `AUTO_PWS_DB=auto_pws`
- `SECRET_KEY` (JWT signing key)
- `SESSION_SECRET_KEY` (Starlette session key)
- `ACCESS_TOKEN_EXPIRE_MINUTES=30`
- `ACCESS_TOKEN_REMEMBER_DAYS=7`

Example values are already in [.env.example](/z:/Projects/pws_auto/.env.example).

## 2. Start the Stack

From repo root:

```powershell
docker compose --env-file .env.local up -d --build
```

Check status:

```powershell
docker compose --env-file .env.local ps
```

## 3. Database Initialization Notes

On a fresh Postgres volume, `admin_pws` is created by:

- [01-create-admin-pws.sh](/z:/Projects/pws_auto/postgres/initdb/01-create-admin-pws.sh)

If you are reusing an old Postgres volume and `admin_pws` does not exist, create it once:

```powershell
@'
SELECT 'CREATE DATABASE admin_pws'
WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='admin_pws');
\gexec
'@ | docker compose --env-file .env.local exec -T postgres psql -U n8n -d postgres
```

## 4. First-Time Usage

1. Open `https://<domain>/pwsadmin/home`
2. Register the first user
3. Every new user is created with `is_active=false`
4. The first registered user also gets `is_admin=true`, but still must be activated manually
5. After setting `users.is_active = true` for that account, login from the same page
6. Open `https://<domain>/pwsadmin/admin` and login with that admin account

## 5. Main Endpoints

### Pages

- `GET /pwsadmin/home`
- `GET /pwsadmin/dashboard`

### Dashboard UI Development

- Tab and subtab extension contract:
  [specs/pwsadmin-tab-subtab-specification.md](/z:/Projects/pws_auto/fastapi/specs/pwsadmin-tab-subtab-specification.md)
- FastAPI UI specs index:
  [specs/README.md](/z:/Projects/pws_auto/fastapi/specs/README.md)
- Step-by-step tab/subtab tutorial:
  [pwsadmin-ui-add-tab-subtab-tutorial.md](/z:/Projects/pws_auto/tutorials/pwsadmin-ui-add-tab-subtab-tutorial.md)

### Auth API

- `POST /pwsadmin/api/auth/register`
- `POST /pwsadmin/api/auth/login`
- `GET /pwsadmin/api/auth/me` (Bearer token required)

### Health

- `GET /pwsadmin/api/health`
- `GET /pwsadmin/api/health/databases`

### Tasks (read-only from `auto_pws`)

- `GET /pwsadmin/api/tasks`
- `GET /pwsadmin/api/tasks/{task_id}`

## 6. Quick API Example (local HTTPS)

If using local self-signed certs:

```powershell
# Login
$loginBody = @{
  email = "admin@example.com"
  password = "AdminPass123!"
  remember_me = $true
} | ConvertTo-Json

$tokenResp = Invoke-RestMethod `
  -Method Post `
  -Uri "https://auto.palmwavestays.lo/pwsadmin/api/auth/login" `
  -ContentType "application/json" `
  -Body $loginBody `
  -SkipCertificateCheck

$token = $tokenResp.access_token

# Me
Invoke-RestMethod `
  -Method Get `
  -Uri "https://auto.palmwavestays.lo/pwsadmin/api/auth/me" `
  -Headers @{ Authorization = "Bearer $token" } `
  -SkipCertificateCheck

# Tasks
Invoke-RestMethod `
  -Method Get `
  -Uri "https://auto.palmwavestays.lo/pwsadmin/api/tasks?limit=10" `
  -Headers @{ Authorization = "Bearer $token" } `
  -SkipCertificateCheck
```

## 7. Important Behavior

- `auto_pws` is enforced as read-only in code (`execute_auto_query`)
- `admin_pws` tables are auto-created at FastAPI startup
- `/pwsadmin/admin` requires admin credentials
- `/pwsadmin/home` login supports `remember_me`:
  - `false` (default): session storage + non-persistent auth cookie
  - `true`: local storage + persistent auth cookie (`ACCESS_TOKEN_REMEMBER_DAYS`)
- Last admin delete is blocked in [admin_views.py](/z:/Projects/pws_auto/fastapi/admin_views.py)

## 8. Troubleshooting

- FastAPI restart loop with `database "admin_pws" does not exist`
  - Create `admin_pws` manually (section 3), then restart FastAPI:
  - `docker compose --env-file .env.local restart fastapi`

- `401` on `/pwsadmin/api/tasks` or `/auth/me`
  - Missing/invalid Bearer token

- `/pwsadmin/admin` keeps redirecting to login
  - Session cookie missing/expired, or user is not admin

## 9. Stop the Stack

```powershell
docker compose --env-file .env.local down
```
