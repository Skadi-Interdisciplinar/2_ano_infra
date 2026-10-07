FROM python:3.11-slim
WORKDIR /app
COPY dist/ /tmp/dist/
COPY start.py /app/start.py
RUN pip install --no-cache-dir --upgrade pip \
    && pip install --no-cache-dir /tmp/dist/*.whl \
    && rm -rf /tmp/dist
EXPOSE 8000
CMD ["python", "/app/start.py"]
