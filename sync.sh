#!/data/data/com.termux/files/usr/bin/bash

# 配置文件路径
CONFIG_FILE="$HOME/.backup_config"

# 检查并加载配置文件
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# 检查环境变量，若缺少则交互输入并保存
prompt_and_save_config() {
    local changed=0
    if [ -z "$WEBDAV_URL" ]; then
        read -p "请输入 WebDAV URL (例如 https://webdav.example.com): " WEBDAV_URL
        changed=1
    fi
    if [ -z "$WEBDAV_USERNAME" ]; then
        read -p "请输入 WebDAV 用户名: " WEBDAV_USERNAME
        changed=1
    fi
    if [ -z "$WEBDAV_PASSWORD" ]; then
        read -s -p "请输入 WebDAV 密码 (输入不会显示): " WEBDAV_PASSWORD
        echo
        changed=1
    fi

    # 如果有输入，则保存到配置文件
    if [ "$changed" -eq 1 ]; then
        cat <<EOF > "$CONFIG_FILE"
export WEBDAV_URL="$WEBDAV_URL"
export WEBDAV_USERNAME="$WEBDAV_USERNAME"
export WEBDAV_PASSWORD="$WEBDAV_PASSWORD"
EOF
        echo "配置已保存到 $CONFIG_FILE"
    fi
}

# 检查环境变量
if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USERNAME" ] || [ -z "$WEBDAV_PASSWORD" ]; then
    echo "缺少 WEBDAV_URL, WEBDAV_USERNAME 或 WEBDAV_PASSWORD，正在提示输入..."
    prompt_and_save_config
    if [ -z "$WEBDAV_URL" ] || [ -z "$WEBDAV_USERNAME" ] || [ -z "$WEBDAV_PASSWORD" ]; then
        echo "仍缺少必要的环境变量，退出备份功能"
        exit 1
    fi
fi

# 设置备份路径
WEBDAV_BACKUP_PATH=${WEBDAV_BACKUP_PATH:-""}
RCLONE_REMOTE="webdav:${WEBDAV_BACKUP_PATH}"
BACKUP_DIR="$HOME/tmp"
mkdir -p "$BACKUP_DIR"

# 配置 rclone（临时写入配置文件）
mkdir -p "$HOME/.config/rclone"
cat <<EOF > "$HOME/.config/rclone/rclone.conf"
[webdav]
type = webdav
url = $WEBDAV_URL
vendor = other
user = $WEBDAV_USERNAME
pass = $(echo "$WEBDAV_PASSWORD" | rclone obscure -)
EOF

# 下载最新备份并恢复
restore_backup() {
    echo "开始从 WebDAV 下载最新备份..."
    # 列出备份文件
    backups=$(rclone lsf "$RCLONE_REMOTE" | grep -E '^backup_.*\.tar\.gz$')
    if [ -z "$backups" ]; then
        echo "没有找到备份文件"
        return
    fi

    # 找到最新的备份文件
    latest_backup=$(echo "$backups" | sort | tail -n 1)
    echo "最新备份文件：$latest_backup"

    # 下载最新备份
    rclone copy "$RCLONE_REMOTE/$latest_backup" "$BACKUP_DIR/"
    if [ $? -eq 0 ] && [ -f "$BACKUP_DIR/$latest_backup" ]; then
        echo "成功下载备份文件到 $BACKUP_DIR/$latest_backup"

        # 如果目标目录已存在，先删除
        for dir in "$HOME/Openlist/data" "$HOME/aria2"; do
            if [ -d "$dir" ]; then
                echo "删除现有的 $dir 目录"
                rm -rf "$dir"
            fi
        done

        # 解压备份文件
        tar -xzf "$BACKUP_DIR/$latest_backup" -C "$HOME/"
        if [ $? -eq 0 ]; then
            echo "成功从 $latest_backup 恢复备份"
        else
            echo "解压备份文件失败"
        fi

        # 清理临时文件
        rm -f "$BACKUP_DIR/$latest_backup"
    else
        echo "下载备份文件失败或文件不存在"
    fi
}

# 首次启动时下载最新备份
echo "Downloading latest backup from WebDAV..."
restore_backup

# 同步函数
sync_data() {
    while true; do
        echo "Starting sync process at $(date)"

        # 检查目录是否存在
        if [ -d "$HOME/Openlist/data" ] || [ -d "$HOME/aria2" ]; then
            timestamp=$(date +%Y%m%d_%H%M%S)
            backup_file="backup_${timestamp}.tar.gz"

            # 备份 Openlist/data 和 aria2 目录
            tar -czf "$BACKUP_DIR/$backup_file" -C "$HOME" Openlist/data aria2 2>/dev/null

            # 上传新备份到 WebDAV
            rclone copy "$BACKUP_DIR/$backup_file" "$RCLONE_REMOTE/"
            if [ $? -eq 0 ]; then
                echo "Successfully uploaded $backup_file to WebDAV"
            else
                echo "Failed to upload $backup_file to WebDAV"
            fi

            # 清理旧备份文件（保留最近 5 个）
            backups=$(rclone lsf "$RCLONE_REMOTE" | grep -E '^backup_.*\.tar\.gz$' | sort)
            backup_count=$(echo "$backups" | wc -l)
            if [ "$backup_count" -gt 5 ]; then
                to_delete=$((backup_count - 5))
                echo "$backups" | head -n "$to_delete" | while read -r file; do
                    rclone delete "$RCLONE_REMOTE/$file"
                    if [ $? -eq 0 ]; then
                        echo "Successfully deleted $file"
                    else
                        echo "Failed to delete $file"
                    fi
                done
            else
                echo "Only $backup_count backups found, no need to clean."
            fi

            # 清理临时文件
            rm -f "$BACKUP_DIR/$backup_file"
        else
            echo "$HOME/Openlist/data and $HOME/aria2 directories do not exist, waiting for next sync..."
        fi

        SYNC_INTERVAL=${SYNC_INTERVAL:-600}
        echo "Next sync in ${SYNC_INTERVAL} seconds..."
        sleep "$SYNC_INTERVAL"
    done
}

# 启动同步进程（后台运行）
sync_data &

# Termux 中保持脚本运行
echo "Backup script running in background..."
wait
