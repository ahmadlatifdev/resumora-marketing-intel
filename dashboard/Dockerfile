FROM python:3.11-slim
WORKDIR /app
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1 PORT=8080 \
    AD_PLATFORM_WRITE_ENABLED=false AUTO_APPLY_PRICE_CHANGES=false \
    BIGQUERY_DATASET=marketing_intelligence
COPY dashboard/requirements.txt /app/requirements.txt
RUN pip install --no-cache-dir -r /app/requirements.txt
COPY modules /app/modules
COPY dashboard /app/dashboard
COPY data /app/data
COPY api /app/api
EXPOSE 8080
CMD ["gunicorn", "-b", "0.0.0.0:8080", "-w", "1", "--timeout", "600", "api.app:app"]
