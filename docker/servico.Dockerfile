FROM python:3.12-slim
WORKDIR /app
COPY app/servico/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/servico/ .
EXPOSE 5001
CMD ["gunicorn", "--bind", "0.0.0.0:5001", "--workers", "2", "--timeout", "60", "--access-logfile", "-", "app:app"]
