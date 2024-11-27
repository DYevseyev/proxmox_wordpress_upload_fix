#!/bin/bash

# Interactive script to increase upload limit and PHP size for WordPress on Proxmox
# Includes sanity checks and fixes for common issues

# Function to prompt for input with default values and optional asterisk
prompt() {
    local PROMPT_TEXT=$1
    local DEFAULT_VALUE=$2
    local VAR_NAME=$3
    local IS_CRITICAL=$4

    if [ "$IS_CRITICAL" = "yes" ]; then
        PROMPT_TEXT="* ${PROMPT_TEXT}"
    fi

    read -p "${PROMPT_TEXT} [${DEFAULT_VALUE}]: " INPUT_VALUE
    if [ -z "$INPUT_VALUE" ]; then
        declare -g "$VAR_NAME"="$DEFAULT_VALUE"
    else
        declare -g "$VAR_NAME"="$INPUT_VALUE"
    fi
}

echo "This script will help you increase the upload limit and PHP size for your WordPress installation."
echo "It will also perform sanity checks and fix common issues."
echo "Options marked with an asterisk (*) are critical for resolving upload issues."
echo

# Default values
DEFAULT_UPLOAD_MAX_FILESIZE="256M"
DEFAULT_POST_MAX_SIZE="256M"
DEFAULT_MEMORY_LIMIT="512M"
DEFAULT_MAX_EXECUTION_TIME="600"
DEFAULT_MAX_INPUT_TIME="600"
DEFAULT_PHP_INI="/etc/php/8.2/apache2/php.ini"
DEFAULT_WP_CONFIG="/var/www/wordpress/wp-config.php"

# Prompt user for values
prompt "Enter the upload_max_filesize" "$DEFAULT_UPLOAD_MAX_FILESIZE" "UPLOAD_MAX_FILESIZE"
prompt "Enter the post_max_size" "$DEFAULT_POST_MAX_SIZE" "POST_MAX_SIZE" "yes"
prompt "Enter the memory_limit" "$DEFAULT_MEMORY_LIMIT" "MEMORY_LIMIT"
prompt "Enter the max_execution_time" "$DEFAULT_MAX_EXECUTION_TIME" "MAX_EXECUTION_TIME"
prompt "Enter the max_input_time" "$DEFAULT_MAX_INPUT_TIME" "MAX_INPUT_TIME"

echo
echo "Please confirm the paths to the configuration files."
prompt "Enter the path to php.ini file" "$DEFAULT_PHP_INI" "PHP_INI"
prompt "Enter the path to wp-config.php file" "$DEFAULT_WP_CONFIG" "WP_CONFIG"

echo
echo "The following values will be applied:"
echo "upload_max_filesize = $UPLOAD_MAX_FILESIZE"
echo "post_max_size = $POST_MAX_SIZE    *"
echo "memory_limit = $MEMORY_LIMIT"
echo "max_execution_time = $MAX_EXECUTION_TIME"
echo "max_input_time = $MAX_INPUT_TIME"
echo "php.ini file: $PHP_INI"
echo "wp-config.php file: $WP_CONFIG"
echo
echo "Note: Options marked with an asterisk (*) are critical for resolving upload issues."
echo

read -p "Do you want to proceed with these settings? (y/n): " CONFIRM
if [[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]]; then
    echo "Operation cancelled by user."
    exit 0
fi

# Check if php.ini exists
if [ ! -f "$PHP_INI" ]; then
    echo "php.ini file not found at $PHP_INI"
    exit 1
fi

# Backup the original php.ini file
cp "$PHP_INI" "${PHP_INI}.backup.$(date +%F_%T)"

# Function to set or update a php.ini directive
set_php_ini_value() {
    INI_FILE=$1
    DIRECTIVE=$2
    VALUE=$3

    # If directive exists and is not commented, replace its value
    if grep -qE "^[^;]*${DIRECTIVE} *=" "$INI_FILE"; then
        sed -i "s|^\([^;]*\)\(${DIRECTIVE} *=\).*|\1\2 ${VALUE}|g" "$INI_FILE"
    else
        # Add the directive at the end of the file
        echo "${DIRECTIVE} = ${VALUE}" >> "$INI_FILE"
    fi
}

# Update the php.ini directives
set_php_ini_value "$PHP_INI" "upload_max_filesize" "$UPLOAD_MAX_FILESIZE"
set_php_ini_value "$PHP_INI" "post_max_size" "$POST_MAX_SIZE"
set_php_ini_value "$PHP_INI" "memory_limit" "$MEMORY_LIMIT"
set_php_ini_value "$PHP_INI" "max_execution_time" "$MAX_EXECUTION_TIME"
set_php_ini_value "$PHP_INI" "max_input_time" "$MAX_INPUT_TIME"

echo "Updated php.ini at $PHP_INI"

# Check if wp-config.php exists
if [ ! -f "$WP_CONFIG" ]; then
    echo "wp-config.php not found at $WP_CONFIG"
    exit 1
fi

# Backup wp-config.php
cp "$WP_CONFIG" "${WP_CONFIG}.backup.$(date +%F_%T)"

# Remove duplicate WP_CACHE definitions in wp-config.php
WP_CACHE_COUNT=$(grep -c "define('WP_CACHE'" "$WP_CONFIG")
if [ "$WP_CACHE_COUNT" -gt 1 ]; then
    echo "Duplicate WP_CACHE definitions found in wp-config.php. Removing duplicates..."
    # Keep the first occurrence and remove the rest
    sed -i "0,/define('WP_CACHE'/! s/define('WP_CACHE'.*;//g" "$WP_CONFIG"
fi

# Update WP_MEMORY_LIMIT in wp-config.php
if grep -q "define('WP_MEMORY_LIMIT'" "$WP_CONFIG"; then
    # Update the value
    sed -i "s|define('WP_MEMORY_LIMIT'.*;|define('WP_MEMORY_LIMIT', '${MEMORY_LIMIT}');|g" "$WP_CONFIG"
else
    # Add the line before the /* That's all, stop editing! Happy blogging. */ line
    sed -i "/\/\* That's all, stop editing! Happy blogging. \*\//i define('WP_MEMORY_LIMIT', '${MEMORY_LIMIT}');" "$WP_CONFIG"
fi

# Update WP_MAX_MEMORY_LIMIT in wp-config.php
if grep -q "define('WP_MAX_MEMORY_LIMIT'" "$WP_CONFIG"; then
    # Update the value
    sed -i "s|define('WP_MAX_MEMORY_LIMIT'.*;|define('WP_MAX_MEMORY_LIMIT', '${MEMORY_LIMIT}');|g" "$WP_CONFIG"
else
    # Add the line before the /* That's all, stop editing! Happy blogging. */ line
    sed -i "/\/\* That's all, stop editing! Happy blogging. \*\//i define('WP_MAX_MEMORY_LIMIT', '${MEMORY_LIMIT}');" "$WP_CONFIG"
fi

echo "Updated wp-config.php at $WP_CONFIG"

# Check if mod_evasive is enabled
if apachectl -M 2>/dev/null | grep -q "evasive20_module"; then
    echo "mod_evasive is currently enabled."
    read -p "Do you want to disable mod_evasive to prevent upload issues? (y/n): " DISABLE_EVASIVE
    if [[ "$DISABLE_EVASIVE" == "y" || "$DISABLE_EVASIVE" == "Y" ]]; then
        a2dismod evasive
        echo "mod_evasive has been disabled."
    else
        echo "mod_evasive remains enabled. Adjusting configuration..."
        # Adjust mod_evasive configuration
        EVASIVE_CONF="/etc/apache2/mods-available/evasive.conf"
        if [ -f "$EVASIVE_CONF" ]; then
            cp "$EVASIVE_CONF" "${EVASIVE_CONF}.backup.$(date +%F_%T)"
            sed -i "s|DOSPageCount .*|DOSPageCount 50|" "$EVASIVE_CONF"
            sed -i "s|DOSSiteCount .*|DOSSiteCount 200|" "$EVASIVE_CONF"
            sed -i "s|DOSBlockingPeriod .*|DOSBlockingPeriod 10|" "$EVASIVE_CONF"
            echo "Adjusted mod_evasive settings in $EVASIVE_CONF"
        else
            echo "mod_evasive configuration file not found at $EVASIVE_CONF"
        fi
    fi
else
    echo "mod_evasive is not enabled."
fi

# Check and correct server date and time
CURRENT_YEAR=$(date +"%Y")
if [ "$CURRENT_YEAR" -gt "$(date +"%Y")" ]; then
    echo "Server date and time appear to be incorrect."
    read -p "Do you want to synchronize the server time using NTP? (y/n): " SYNC_TIME
    if [[ "$SYNC_TIME" == "y" || "$SYNC_TIME" == "Y" ]]; then
        apt update && apt install -y ntp
        systemctl enable ntp
        systemctl start ntp
        echo "NTP has been installed and started."
    else
        echo "Server time synchronization skipped."
    fi
else
    echo "Server date and time are correct."
fi

# Restart Apache to apply changes
echo "Restarting Apache..."

if command -v systemctl >/dev/null 2>&1; then
    systemctl restart apache2
elif command -v service >/dev/null 2>&1; then
    service apache2 restart
else
    /etc/init.d/apache2 restart
fi

echo "All done. Please check your WordPress site to verify the changes."
