# setup_auth_rbac.ps1
$projectRoot = "fastapi_auth_rbac"
$appFile = "$projectRoot\app.py"
$authFile = "$projectRoot\auth.py"
$modelsFile = "$projectRoot\models.py"
$sqlFile = "$projectRoot\sql_server.py"
$reqFile = "$projectRoot\requirements.txt"

Write-Host "Creating project directory..."
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

Write-Host "Writing requirements.txt..."
@"
fastapi
uvicorn
pydantic
sqlalchemy
duckdb
python-jose
passlib[bcrypt]
"@ | Set-Content -Path $reqFile

Write-Host "Writing auth.py..."
@"
from passlib.context import CryptContext
from jose import jwt, JWTError
from datetime import datetime, timedelta

SECRET_KEY = "your-secret-key"
ALGORITHM = "HS256"
ACCESS_TOKEN_EXPIRE_MINUTES = 30

pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")

def hash_password(password: str) -> str:
    return pwd_context.hash(password)

def verify_password(plain: str, hashed: str) -> bool:
    return pwd_context.verify(plain, hashed)

def create_access_token(data: dict, expires_delta: timedelta = None):
    to_encode = data.copy()
    expire = datetime.utcnow() + (expires_delta or timedelta(minutes=ACCESS_TOKEN_EXPIRE_MINUTES))
    to_encode.update({"exp": expire})
    return jwt.encode(to_encode, SECRET_KEY, algorithm=ALGORITHM)

def decode_token(token: str):
    try:
        return jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
    except JWTError:
        return None
"@ | Set-Content -Path $authFile

Write-Host "🧬 Writing models.py..."
@"
from sqlalchemy import Column, Integer, String, MetaData, Table
from sqlalchemy.orm import registry
from pydantic import BaseModel

mapper_registry = registry()
metadata = MetaData()

user_table = Table(
    "users",
    metadata,
    Column("id", Integer, primary_key=True),
    Column("username", String, unique=True),
    Column("password", String),
    Column("role", String),
)

@mapper_registry.mapped
class User:
    __table__ = user_table

class UserCreate(BaseModel):
    username: str
    password: str
    role: str

class UserLogin(BaseModel):
    username: str
    password: str
"@ | Set-Content -Path $modelsFile

Write-Host "Writing sql_server.py..."
@"
import os
from sqlalchemy import create_engine

def get_engine():
    base_dir = os.path.dirname(__file__)
    db_path = os.path.join(base_dir, "authlab.duckdb")
    return create_engine(f"duckdb:///{db_path}")
"@ | Set-Content -Path $sqlFile

Write-Host "Writing app.py..."
@"
from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.security import OAuth2PasswordBearer
from sqlalchemy.orm import Session
from sqlalchemy import select, text
from auth import hash_password, verify_password, create_access_token, decode_token
from models import User, UserCreate, UserLogin, metadata
from sql_server import get_engine

app = FastAPI()
engine = get_engine()
metadata.create_all(engine)
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="login")

def get_user_by_username(session: Session, username: str):
    stmt = select(User).where(User.username == username)
    return session.execute(stmt).scalar_one_or_none()

def get_current_user(token: str = Depends(oauth2_scheme)):
    payload = decode_token(token)
    if not payload:
        raise HTTPException(status_code=401, detail="Invalid token")
    return payload

def require_role(role: str):
    def role_checker(user=Depends(get_current_user)):
        if user.get("role") != role:
            raise HTTPException(status_code=403, detail="Forbidden")
        return user
    return role_checker

@app.post("/register")
def register(user: UserCreate):
    with Session(engine) as session:
        if get_user_by_username(session, user.username):
            raise HTTPException(status_code=400, detail="User already exists")
        new_user = User(
            username=user.username,
            password=hash_password(user.password),
            role=user.role
        )
        session.add(new_user)
        session.commit()
        return {"msg": "User registered"}

@app.post("/login")
def login(credentials: UserLogin):
    with Session(engine) as session:
        user = get_user_by_username(session, credentials.username)
        if not user or not verify_password(credentials.password, user.password):
            raise HTTPException(status_code=401, detail="Invalid credentials")
        token = create_access_token({"sub": user.username, "role": user.role})
        return {"access_token": token, "token_type": "bearer"}

@app.get("/admin")
def admin_only(user=Depends(require_role("admin"))):
    return {"msg": f"Welcome admin {user['sub']}"}

@app.get("/user")
def user_only(user=Depends(require_role("user"))):
    return {"msg": f"Welcome user {user['sub']}"}
"@ | Set-Content -Path $appFile

Write-Host "Auth + RBAC lab scaffolded in '$projectRoot'."
Write-Host "`nTo get started:"
Write-Host "    cd $projectRoot"
Write-Host "    python -m venv venv"
Write-Host "    .\\venv\\Scripts\\Activate.ps1   # Windows"
Write-Host "    source venv/bin/activate         # Linux/macOS"
Write-Host "    pip install -r requirements.txt"
Write-Host "    uvicorn app:app --reload"