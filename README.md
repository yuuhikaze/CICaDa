# CICaDA

CI/CD done at caveman level.

### Principles

-   Publish services through traefik.
-   Roll updates through webhooks using the blue/green strategy.

### Execution

1.  Create the reverse proxy network.

    ```bash
    sudo docker network create traefik_proxy
    ```

1.  Run traefik and webhook server.

    ```bash
    sudo docker compose up -d
    ```

### Blue/green deployment

1.  Install go.

    ```bash
    sudo dnf install -y golang
    ```

1.  Install adnanh/webhook.

    ```bash
    sudo env GOBIN=/usr/local/bin go install github.com/adnanh/webhook@2.8.2
    ```
