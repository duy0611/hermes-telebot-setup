# Rollback — hermes-telebot gateway (2026-11-05T19:42:56+02:00)

The isolated gateway reuses the original bot token, so the old user unit was
stopped and DISABLED (`systemctl --user disable --now hermes-gateway`).

## Go back to the old gateway

    sudo systemctl disable --now hermes-gateway
    systemctl --user enable --now hermes-gateway
    hermes gateway status

## Full teardown

    sudo systemctl disable --now hermes-gateway
    sudo rm -f /etc/systemd/system/hermes-gateway.service
    sudo rm -rf /etc/systemd/system/hermes-gateway.service.d
    sudo systemctl daemon-reload
    loginctl disable-linger hermes-telebot
    sudo userdel -r hermes-telebot

No ACL grants were made, so there is nothing to revoke. If that changes, remove
them before `userdel` — UIDs get reused:

    sudo setfacl -R -x u:hermes-telebot <DIR>
    sudo find <DIR> -type d -exec setfacl -x d:u:hermes-telebot {} +

## Re-running

    sudo bash /home/dnguyen/Projects/hermes-telebot-setup/hermes-telebot-provision.sh
