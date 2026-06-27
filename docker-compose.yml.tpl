services:
  minio:
    container_name: {{MINIO_CONTAINER_NAME}}
    image: minio/minio:latest
    restart: unless-stopped
    command: server /data --console-address ":9001"
    environment:
      MINIO_ROOT_USER: {{MINIO_ROOT_USER_YAML}}
      MINIO_ROOT_PASSWORD_FILE: /run/secrets/root_password
{{PUBLIC_URL_ENV_SECTION}}
    volumes:
      - {{MINIO_DATA_PATH}}:/data
      - {{MINIO_ROOT_PASSWORD_SECRET_PATH}}:/run/secrets/root_password:ro
{{PORTS_SECTION}}
    networks:
      - {{MINIO_NETWORK}}
    healthcheck:
      test: ["CMD", "curl", "-f", "http://127.0.0.1:9000/minio/health/live"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 40s

networks:
  {{MINIO_NETWORK}}:
    external: true
