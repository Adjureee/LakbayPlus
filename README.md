# Lakbay+ Monorepo

Unified monorepo for **Lakbay+** (Davao Region / Region XI AI Travel Companion), structured identically to the reference architecture for **Render** + **Neon PostgreSQL/PostGIS** deployment.

## Structure

| Path | Purpose | Stack |
| :--- | :--- | :--- |
| `apps/traveler_app` | Lakbay+ Traveler mobile & web client (`lakbay_travel`) | Flutter + Mapbox + Groq/Gemini AI + Cloudinary |
| `apps/admin_app` | Lakbay+ Admin Web workspace (`lakbay_admin`) | Flutter Web (`build/web`) |
| `services/api` | Versioned `/api/v1` REST API & AI planner backend | FastAPI, async SQLAlchemy, Alembic, Neon Postgres/PostGIS |
| `render.yaml` | Render Blueprint for `lakbay-api` and `lakbay-admin` | Render Web Service + Static Site |

---

## 1. Local Backend Setup (`services/api`)

```powershell
cd services/api
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt -r requirements-dev.txt
.\.venv\Scripts\python.exe -m alembic upgrade head
.\.venv\Scripts\python.exe -m app.seeds.davao_destinations
.\.venv\Scripts\python.exe -m uvicorn app.main:app --reload
```

Verify health at `http://127.0.0.1:8000/api/v1/health`.

Register a local admin account:

```powershell
.\.venv\Scripts\python.exe scripts/register_admin.py --base-url http://127.0.0.1:8000/api/v1
```

## 2. Run Apps Locally

**Traveler App (`apps/traveler_app`)**:
```powershell
cd apps/traveler_app
flutter pub get
flutter run -d chrome
```

**Admin Web App (`apps/admin_app`)**:
```powershell
cd apps/admin_app
flutter pub get
flutter run -d chrome --web-port=5173 --dart-define=API_BASE_URL=http://127.0.0.1:8000/api/v1
```

## 3. Cloud Deployment (Render + Neon)

### Step A — Neon PostgreSQL + PostGIS
1. Create a Neon PostgreSQL database and ensure PostGIS is enabled (`CREATE EXTENSION IF NOT EXISTS postgis;`).
2. Run `alembic upgrade head` and `python -m app.seeds.davao_destinations` against your production `DATABASE_URL`.

### Step B — Deploy `services/api` on Render
- Connect this repository on Render (or import `render.yaml`).
- Web Service **Root Directory**: `services/api`
- **Build Command**: `pip install -r requirements.txt`
- **Start Command**: `uvicorn app.main:app --host 0.0.0.0 --port $PORT`
- **Health Check Path**: `/api/v1/health`
- Set secrets in Render **Environment** (`DATABASE_URL`, `JWT_SECRET_KEY`, `ADMIN_REGISTRATION_CODE`, `GROQ_API_KEY`, `FALLBACK_LLM_API_KEY`, `CLOUDINARY_*`, `CORS_ALLOWED_ORIGINS`).

Register your production admin account once the Render API is live:

```powershell
python services/api/scripts/register_admin.py --base-url https://<your-lakbay-api>.onrender.com/api/v1
```

### Step C — Build & Deploy `apps/admin_app` (`build/web`)
1. Build the static bundle pointing to your live Render API URL:
   ```powershell
   cd apps/admin_app
   flutter build web --release --dart-define=API_BASE_URL=https://<your-lakbay-api>.onrender.com/api/v1
   ```
2. Deploy `apps/admin_app/build/web` to Render Static Site (or Cloudflare Pages / Vercel / Netlify) with a SPA rewrite (`/* -> /index.html`).
3. Update `CORS_ALLOWED_ORIGINS` on Render `lakbay-api` to match your exact Admin Web origin (for example `https://lakbay-admin.onrender.com`, no trailing slash).
