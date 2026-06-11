FROM python:3.11-slim

WORKDIR /app

# Instala dependências nativas leves
RUN pip install --no-cache-dir fastapi uvicorn requests

# Copia o código da ponte de autenticação
COPY main.py .

EXPOSE 5000

CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "5000"]
