FROM python:3.11-slim
WORKDIR /app
COPY pyproject.toml /app/pyproject.toml
COPY design.md /app/design.md
COPY app /app/app
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir .
EXPOSE 8000
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
