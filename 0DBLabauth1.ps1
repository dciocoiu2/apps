# Define project structure
$projectRoot   = "app1"
$appFile       = "$projectRoot\app.py"
$sqlFile       = "$projectRoot\sql_server.py"
$reqFile       = "$projectRoot\requirements.txt"

# Create project directory
Write-Host "Creating project directory..."
New-Item -ItemType Directory -Path $projectRoot -Force | Out-Null

# Write requirements.txt
Write-Host "Writing requirements.txt..."
@"
fastapi
uvicorn
pandas
numpy
pydantic
sqlalchemy
duckdb
passlib[bcrypt]
python-jose
"@ | Set-Content -Path $reqFile

# Write sql_server.py
Write-Host "Writing sql_server.py..."
@"
import os
from sqlalchemy import create_engine, text

def get_engine():
    base_dir = os.path.dirname(__file__)
    db_path = os.path.join(base_dir, 'mydb.duckdb')
    return create_engine(f'duckdb:///{db_path}')

def init_db():
    with get_engine().begin() as conn:
        conn.execute(text(\"\"\"
            CREATE TABLE IF NOT EXISTS roles (
                id INTEGER PRIMARY KEY,
                name TEXT UNIQUE
            );
        \"\"\"))
        conn.execute(text(\"\"\"
            CREATE TABLE IF NOT EXISTS users (
                id INTEGER PRIMARY KEY,
                name TEXT,
                email TEXT UNIQUE,
                password TEXT,
                role_id INTEGER,
                FOREIGN KEY(role_id) REFERENCES roles(id)
            );
        \"\"\"))
        conn.execute(text(\"\"\"
            INSERT OR IGNORE INTO roles (id, name) VALUES
            (1, 'admin'),
            (2, 'user');
        \"\"\"))
"@ | Set-Content -Path $sqlFile

# Write app.py
Write-Host "Writing app.py..."
@"
from fastapi import FastAPI, HTTPException, Depends
from fastapi.security import OAuth2PasswordBearer, OAuth2PasswordRequestForm
from pydantic import BaseModel
from sqlalchemy import Column, Integer, String, ForeignKey, MetaData, Table, select, text
from sqlalchemy.orm import registry, Session
from passlib.context import CryptContext
from jose import JWTError, jwt
from sql_server import get_engine, init_db

SECRET_KEY = "your-secret-key"
ALGORITHM = "HS256"
pwd_context = CryptContext(schemes=["bcrypt"], deprecated="auto")
oauth2_scheme = OAuth2PasswordBearer(tokenUrl="token")

mapper_registry = registry()
metadata = MetaData()

role_table = Table(
    "roles", metadata,
    Column("id", Integer, primary_key=True),
    Column("name", String, unique=True)
)

user_table = Table(
    "users", metadata,
    Column("id", Integer, primary_key=True),
    Column("name", String),
    Column("email", String, unique=True),
    Column("password", String),
    Column("role_id", Integer, ForeignKey("roles.id"))
)

@mapper_registry.mapped
class Role:
    __table__ = role_table

@mapper_registry.mapped
class User:
    __table__ = user_table

class UserAuth(BaseModel):
    name: str
    email: str
    password: str
    role: str = "user"

class Token(BaseModel):
    access_token: str
    token_type: str

app = FastAPI()
engine = get_engine()
init_db()

def get_password_hash(password):
    return pwd_context.hash(password)

def verify_password(plain, hashed):
    return pwd_context.verify(plain, hashed)

def create_access_token(data: dict):
    return jwt.encode(data, SECRET_KEY, algorithm=ALGORITHM)

def get_current_user(token: str = Depends(oauth2_scheme)):
    try:
        payload = jwt.decode(token, SECRET_KEY, algorithms=[ALGORITHM])
        return payload
    except JWTError:
        raise HTTPException(status_code=401, detail="Invalid token")

def require_role(required_role: str):
    def role_checker(user=Depends(get_current_user)):
        if user["role"] != required_role:
            raise HTTPException(status_code=403, detail="Forbidden")
    return role_checker

@app.post("/signup/")
def signup(user: UserAuth):
    hashed_pw = get_password_hash(user.password)
    with Session(engine) as session:
        role_id = session.execute(select(Role.id).where(Role.name == user.role)).scalar_one()
        new_user = User(name=user.name, email=user.email, password=hashed_pw, role_id=role_id)
        session.add(new_user)
        session.commit()
        return {"msg": "User created"}

@app.post("/token", response_model=Token)
def login(form_data: OAuth2PasswordRequestForm = Depends()):
    with Session(engine) as session:
        user = session.execute(select(User).where(User.email == form_data.username)).scalar_one_or_none()
        if not user or not verify_password(form_data.password, user.password):
            raise HTTPException(status_code=401, detail="Invalid credentials")
        role_name = session.execute(select(Role.name).where(Role.id == user.role_id)).scalar_one()
        token = create_access_token({"sub": user.email, "role": role_name})
        return {"access_token": token, "token_type": "bearer"}

@app.get("/admin/")
def admin_dashboard(user=Depends(require_role("admin"))):
    return {"msg": "Welcome, admin!"}
"@ | Set-Content -Path $appFile

# Final instructions
Write-Host "Lab scaffolded in '$projectRoot'."
Write-Host "To get started:"
Write-Host "cd $projectRoot"
Write-Host "python -m venv venv"
Write-Host ".\\venv\\Scripts\\Activate.ps1   # Windows"
Write-Host "source venv/bin/activate         # Linux/macOS"
Write-Host "pip install -r requirements.txt"
Write-Host "uvicorn app:app --reload"