FROM python:3.12-slim
WORKDIR /app
COPY app/gateway/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/gateway/ .
EXPOSE 5000
CMD ["gunicorn", "--bind", "0.0.0.0:5000", "app:app"]
