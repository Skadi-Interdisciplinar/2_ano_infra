FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt /tmp/requirements.txt
COPY app /app/app
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir -r /tmp/requirements.txt \
    && rm /tmp/requirements.txt
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
