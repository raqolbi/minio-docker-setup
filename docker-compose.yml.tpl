services:
  minio:
    container_name: {{MINIO_CONTAINER_NAME}}
    image: {{MINIO_IMAGE}}
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
      # mc/mcli is bundled in the pgsty/silo image.
      test: ["CMD", "mc", "ready", "local"]
      interval: 15s
      timeout: 10s
      retries: 5
      start_period: 30s
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "5"

networks:
  {{MINIO_NETWORK}}:
    external: true
