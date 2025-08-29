/**
 * Tab5 Media Player - Working Clock Display
 * This version has the working clock without flashing
 */

#include <stdio.h>
#include <string.h>
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "freertos/semphr.h"
#include "esp_log.h"
#include "esp_err.h"

// Display drivers
#include "esp_lcd_panel_ops.h"
#include "esp_lcd_mipi_dsi.h"
#include "esp_lcd_ili9881c.h"
#include "esp_ldo_regulator.h"
#include "driver/i2c_master.h"
#include "driver/ledc.h"
#include "driver/gpio.h"

// Include init data
#include "board/ili9881_init_data.h"

static const char *TAG = "Tab5Clock";

// Display configuration
#define LCD_WIDTH           720
#define LCD_HEIGHT          1280
#define LCD_BITS_PER_PIXEL  16
#define BACKLIGHT_GPIO      GPIO_NUM_22

// I2C configuration
#define I2C_SCL_GPIO        GPIO_NUM_32
#define I2C_SDA_GPIO        GPIO_NUM_31

// PI4IOE5V6416 addresses
#define PI4IO_ADDR_1        0x43
#define PI4IO_ADDR_2        0x44

static esp_lcd_panel_handle_t lcd_panel = NULL;
static i2c_master_bus_handle_t i2c_bus = NULL;
static SemaphoreHandle_t refresh_semaphore = NULL;
static uint16_t *frame_buffer = NULL;

// Callback for DPI panel refresh done
static bool on_refresh_done(esp_lcd_panel_handle_t panel, esp_lcd_dpi_panel_event_data_t *edata, void *user_ctx)
{
    SemaphoreHandle_t sem = (SemaphoreHandle_t)user_ctx;
    BaseType_t xHigherPriorityTaskWoken = pdFALSE;
    xSemaphoreGiveFromISR(sem, &xHigherPriorityTaskWoken);
    return (xHigherPriorityTaskWoken == pdTRUE);
}

// Initialize I2C and PI4IO expanders
static esp_err_t init_i2c_pi4io(void)
{
    ESP_LOGI(TAG, "Initializing I2C and PI4IO expanders...");
    
    i2c_master_bus_config_t bus_config = {
        .i2c_port = I2C_NUM_0,
        .sda_io_num = I2C_SDA_GPIO,
        .scl_io_num = I2C_SCL_GPIO,
        .clk_source = I2C_CLK_SRC_DEFAULT,
        .glitch_ignore_cnt = 7,
        .flags.enable_internal_pullup = true,
    };
    
    ESP_ERROR_CHECK(i2c_new_master_bus(&bus_config, &i2c_bus));
    
    // Configure PI4IO at 0x43
    i2c_device_config_t dev_cfg = {
        .dev_addr_length = I2C_ADDR_BIT_LEN_7,
        .device_address = PI4IO_ADDR_1,
        .scl_speed_hz = 400000,
    };
    
    i2c_master_dev_handle_t pi4io_1;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_bus, &dev_cfg, &pi4io_1));
    
    // Reset PI4IO #1
    uint8_t reset[] = {0x01, 0xFF};
    i2c_master_transmit(pi4io_1, reset, 2, pdMS_TO_TICKS(100));
    vTaskDelay(pdMS_TO_TICKS(10));
    
    // Configure PI4IO #1 registers
    uint8_t cmd1[] = {0x03, 0x7F}; // IO_DIR
    uint8_t cmd2[] = {0x07, 0x00}; // OUT_H_IM
    uint8_t cmd3[] = {0x0D, 0x7F}; // PULL_SEL
    uint8_t cmd4[] = {0x0B, 0x7F}; // PULL_EN
    uint8_t cmd5[] = {0x05, 0x76}; // OUT_SET
    
    i2c_master_transmit(pi4io_1, cmd1, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_1, cmd2, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_1, cmd3, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_1, cmd4, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_1, cmd5, 2, pdMS_TO_TICKS(100));
    
    // Configure PI4IO at 0x44
    dev_cfg.device_address = PI4IO_ADDR_2;
    i2c_master_dev_handle_t pi4io_2;
    ESP_ERROR_CHECK(i2c_master_bus_add_device(i2c_bus, &dev_cfg, &pi4io_2));
    
    i2c_master_transmit(pi4io_2, reset, 2, pdMS_TO_TICKS(100));
    vTaskDelay(pdMS_TO_TICKS(10));
    
    uint8_t cmd6[] = {0x03, 0xB9}; // IO_DIR
    uint8_t cmd7[] = {0x07, 0x06}; // OUT_H_IM
    uint8_t cmd8[] = {0x0D, 0xB9}; // PULL_SEL
    uint8_t cmd9[] = {0x0B, 0xF9}; // PULL_EN
    uint8_t cmd10[] = {0x09, 0x40}; // IN_DEF_STA
    uint8_t cmd11[] = {0x11, 0xBF}; // INT_MASK
    uint8_t cmd12[] = {0x05, 0x09}; // OUT_SET
    
    i2c_master_transmit(pi4io_2, cmd6, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd7, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd8, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd9, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd10, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd11, 2, pdMS_TO_TICKS(100));
    i2c_master_transmit(pi4io_2, cmd12, 2, pdMS_TO_TICKS(100));
    
    ESP_LOGI(TAG, "PI4IO expanders configured");
    return ESP_OK;
}

// Initialize display
static esp_err_t init_display(void)
{
    ESP_LOGI(TAG, "Initializing display...");
    
    refresh_semaphore = xSemaphoreCreateBinary();
    if (!refresh_semaphore) {
        ESP_LOGE(TAG, "Failed to create semaphore");
        return ESP_FAIL;
    }
    
    // Initialize backlight PWM
    ledc_timer_config_t ledc_timer = {
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .duty_resolution = LEDC_TIMER_12_BIT,
        .timer_num = LEDC_TIMER_0,
        .freq_hz = 5000,
        .clk_cfg = LEDC_AUTO_CLK,
    };
    ESP_ERROR_CHECK(ledc_timer_config(&ledc_timer));
    
    ledc_channel_config_t ledc_channel = {
        .gpio_num = BACKLIGHT_GPIO,
        .speed_mode = LEDC_LOW_SPEED_MODE,
        .channel = LEDC_CHANNEL_0,
        .timer_sel = LEDC_TIMER_0,
        .duty = 0,
        .hpoint = 0,
    };
    ESP_ERROR_CHECK(ledc_channel_config(&ledc_channel));
    
    // Enable MIPI DSI PHY power
    ESP_LOGI(TAG, "Enabling MIPI DSI PHY power...");
    esp_ldo_channel_handle_t ldo_mipi_phy = NULL;
    esp_ldo_channel_config_t ldo_config = {
        .chan_id = 3,
        .voltage_mv = 2500,
    };
    ESP_ERROR_CHECK(esp_ldo_acquire_channel(&ldo_config, &ldo_mipi_phy));
    
    // Configure MIPI DSI bus
    ESP_LOGI(TAG, "Configuring MIPI DSI bus...");
    esp_lcd_dsi_bus_handle_t dsi_bus;
    esp_lcd_dsi_bus_config_t bus_config = {
        .bus_id = 0,
        .num_data_lanes = 2,
        .phy_clk_src = MIPI_DSI_PHY_CLK_SRC_DEFAULT,
        .lane_bit_rate_mbps = 730,
    };
    ESP_ERROR_CHECK(esp_lcd_new_dsi_bus(&bus_config, &dsi_bus));
    
    // Configure DBI panel IO
    ESP_LOGI(TAG, "Configuring DBI panel IO...");
    esp_lcd_panel_io_handle_t dbi_io;
    esp_lcd_dbi_io_config_t dbi_config = {
        .virtual_channel = 0,
        .lcd_cmd_bits = 8,
        .lcd_param_bits = 8,
    };
    ESP_ERROR_CHECK(esp_lcd_new_panel_io_dbi(dsi_bus, &dbi_config, &dbi_io));
    
    // Configure DPI panel
    ESP_LOGI(TAG, "Configuring DPI panel...");
    esp_lcd_dpi_panel_config_t dpi_config = {
        .virtual_channel = 0,
        .dpi_clk_src = MIPI_DSI_DPI_CLK_SRC_DEFAULT,
        .dpi_clock_freq_mhz = 60,
        .pixel_format = LCD_COLOR_PIXEL_FORMAT_RGB565,
        .num_fbs = 1,
        .video_timing = {
            .h_size = LCD_WIDTH,
            .v_size = LCD_HEIGHT,
            .hsync_pulse_width = 40,
            .hsync_back_porch = 140,
            .hsync_front_porch = 40,
            .vsync_pulse_width = 4,
            .vsync_back_porch = 20,
            .vsync_front_porch = 20,
        },
        .flags = {
            .use_dma2d = 1,
        },
    };
    
    // Create ILI9881C panel
    ESP_LOGI(TAG, "Creating ILI9881C panel...");
    ili9881c_vendor_config_t vendor_config = {
        .init_cmds = tab5_lcd_ili9881c_specific_init_code_default,
        .init_cmds_size = sizeof(tab5_lcd_ili9881c_specific_init_code_default) / sizeof(ili9881c_lcd_init_cmd_t),
        .mipi_config = {
            .dsi_bus = dsi_bus,
            .dpi_config = &dpi_config,
            .lane_num = 2,
        },
    };
    
    esp_lcd_panel_dev_config_t panel_config = {
        .reset_gpio_num = -1,
        .rgb_ele_order = LCD_RGB_ELEMENT_ORDER_RGB,
        .data_endian = LCD_RGB_DATA_ENDIAN_BIG,
        .bits_per_pixel = 16,
        .vendor_config = &vendor_config,
    };
    
    ESP_ERROR_CHECK(esp_lcd_new_panel_ili9881c(dbi_io, &panel_config, &lcd_panel));
    
    // Initialize panel
    ESP_LOGI(TAG, "Initializing panel...");
    ESP_ERROR_CHECK(esp_lcd_panel_reset(lcd_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_init(lcd_panel));
    ESP_ERROR_CHECK(esp_lcd_panel_disp_on_off(lcd_panel, true));
    
    // Register refresh callback
    esp_lcd_dpi_panel_event_callbacks_t callbacks = {
        .on_refresh_done = on_refresh_done,
    };
    ESP_ERROR_CHECK(esp_lcd_dpi_panel_register_event_callbacks(lcd_panel, &callbacks, refresh_semaphore));
    
    // Get frame buffer
    ESP_LOGI(TAG, "Getting DPI panel frame buffer...");
    void *fb;
    ESP_ERROR_CHECK(esp_lcd_dpi_panel_get_frame_buffer(lcd_panel, 1, &fb));
    frame_buffer = (uint16_t *)fb;
    
    xSemaphoreGive(refresh_semaphore);
    
    ESP_LOGI(TAG, "Display initialized, frame buffer at %p", frame_buffer);
    return ESP_OK;
}

// Simple digit drawing (8x8 font)
static const uint8_t digits[10][8] = {
    {0x3C, 0x66, 0x6E, 0x76, 0x66, 0x66, 0x3C, 0x00}, // 0
    {0x18, 0x38, 0x18, 0x18, 0x18, 0x18, 0x7E, 0x00}, // 1
    {0x3C, 0x66, 0x06, 0x0C, 0x30, 0x60, 0x7E, 0x00}, // 2
    {0x3C, 0x66, 0x06, 0x1C, 0x06, 0x66, 0x3C, 0x00}, // 3
    {0x0C, 0x1C, 0x3C, 0x6C, 0x7E, 0x0C, 0x0C, 0x00}, // 4
    {0x7E, 0x60, 0x7C, 0x06, 0x06, 0x66, 0x3C, 0x00}, // 5
    {0x3C, 0x60, 0x60, 0x7C, 0x66, 0x66, 0x3C, 0x00}, // 6
    {0x7E, 0x66, 0x06, 0x0C, 0x18, 0x18, 0x18, 0x00}, // 7
    {0x3C, 0x66, 0x66, 0x3C, 0x66, 0x66, 0x3C, 0x00}, // 8
    {0x3C, 0x66, 0x66, 0x3E, 0x06, 0x06, 0x3C, 0x00}, // 9
};

static void draw_digit(int digit, int x, int y, int scale, uint16_t color) {
    if (digit < 0 || digit > 9) return;
    for (int row = 0; row < 8; row++) {
        uint8_t line = digits[digit][row];
        for (int col = 0; col < 8; col++) {
            if (line & (0x80 >> col)) {
                for (int sy = 0; sy < scale; sy++) {
                    for (int sx = 0; sx < scale; sx++) {
                        int px = x + col * scale + sx;
                        int py = y + row * scale + sy;
                        if (px >= 0 && px < LCD_WIDTH && py >= 0 && py < LCD_HEIGHT) {
                            frame_buffer[py * LCD_WIDTH + px] = color;
                        }
                    }
                }
            }
        }
    }
}

// Clock task - optimized to only update changing digits
static void clock_task(void *arg)
{
    int hour = 12, minute = 0, second = 0;
    int last_second = -1, last_minute = -1, last_hour = -1;
    bool first_draw = true;
    ESP_LOGI(TAG, "Clock task started");
    
    // Clock position and sizing
    int x = LCD_WIDTH/2 - 240;
    int y = LCD_HEIGHT/2 - 40;
    int scale = 10;
    uint16_t color = 0xFFFF; // White
    uint16_t bg_color = 0x0000; // Black
    
    while (1) {
        // Only update if time has changed
        if (first_draw) {
            // Clear entire screen once
            memset(frame_buffer, 0, LCD_WIDTH * LCD_HEIGHT * 2);
            
            // Draw colons (they never change)
            for (int i = 0; i < scale; i++) {
                frame_buffer[(y + scale * 2 + i/3) * LCD_WIDTH + (x + scale * 20 + i/3)] = color;
                frame_buffer[(y + scale * 5 + i/3) * LCD_WIDTH + (x + scale * 20 + i/3)] = color;
                frame_buffer[(y + scale * 2 + i/3) * LCD_WIDTH + (x + scale * 45 + i/3)] = color;
                frame_buffer[(y + scale * 5 + i/3) * LCD_WIDTH + (x + scale * 45 + i/3)] = color;
            }
            
            // Draw status indicator once
            for (int dy = 0; dy < 10; dy++) {
                for (int dx = 0; dx < 10; dx++) {
                    frame_buffer[(50 + dy) * LCD_WIDTH + (50 + dx)] = 0x07E0; // Green
                }
            }
            
            first_draw = false;
        }
        
        // Update hours if changed
        if (hour != last_hour) {
            // Clear old hour digits area
            for (int cy = y; cy < y + scale * 8; cy++) {
                for (int cx = x; cx < x + scale * 18; cx++) {
                    if (frame_buffer[cy * LCD_WIDTH + cx] != 0x07E0) { // Don't clear green dot
                        frame_buffer[cy * LCD_WIDTH + cx] = bg_color;
                    }
                }
            }
            // Draw new hour
            draw_digit(hour / 10, x, y, scale, color);
            draw_digit(hour % 10, x + scale * 10, y, scale, color);
            last_hour = hour;
        }
        
        // Update minutes if changed
        if (minute != last_minute) {
            // Clear old minute digits area
            for (int cy = y; cy < y + scale * 8; cy++) {
                for (int cx = x + scale * 25; cx < x + scale * 43; cx++) {
                    frame_buffer[cy * LCD_WIDTH + cx] = bg_color;
                }
            }
            // Draw new minute
            draw_digit(minute / 10, x + scale * 25, y, scale, color);
            draw_digit(minute % 10, x + scale * 35, y, scale, color);
            last_minute = minute;
        }
        
        // Update seconds
        if (second != last_second) {
            // Clear old second digits area
            for (int cy = y; cy < y + scale * 8; cy++) {
                for (int cx = x + scale * 50; cx < x + scale * 68; cx++) {
                    frame_buffer[cy * LCD_WIDTH + cx] = bg_color;
                }
            }
            // Draw new second
            draw_digit(second / 10, x + scale * 50, y, scale, color);
            draw_digit(second % 10, x + scale * 60, y, scale, color);
            last_second = second;
            
            // Only refresh display when seconds change
            xSemaphoreTake(refresh_semaphore, pdMS_TO_TICKS(100));
            esp_lcd_panel_draw_bitmap(lcd_panel, 0, 0, LCD_WIDTH, LCD_HEIGHT, frame_buffer);
        }
        
        // Update time
        second++;
        if (second >= 60) {
            second = 0;
            minute++;
            if (minute >= 60) {
                minute = 0;
                hour++;
                if (hour >= 24) hour = 0;
            }
        }
        
        vTaskDelay(pdMS_TO_TICKS(1000));
    }
}

void app_main(void)
{
    ESP_LOGI(TAG, "Tab5 Clock Display - Working Version");
    
    // Initialize hardware
    ESP_ERROR_CHECK(init_i2c_pi4io());
    vTaskDelay(pdMS_TO_TICKS(100));
    
    ESP_ERROR_CHECK(init_display());
    vTaskDelay(pdMS_TO_TICKS(100));
    
    // Clear screen initially
    memset(frame_buffer, 0, LCD_WIDTH * LCD_HEIGHT * 2);
    xSemaphoreTake(refresh_semaphore, pdMS_TO_TICKS(100));
    esp_lcd_panel_draw_bitmap(lcd_panel, 0, 0, LCD_WIDTH, LCD_HEIGHT, frame_buffer);
    
    // Turn on backlight
    ESP_LOGI(TAG, "Turning on backlight...");
    ESP_ERROR_CHECK(ledc_set_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0, 2048)); // 50%
    ESP_ERROR_CHECK(ledc_update_duty(LEDC_LOW_SPEED_MODE, LEDC_CHANNEL_0));
    
    // Start clock task immediately
    xTaskCreatePinnedToCore(clock_task, "clock", 8192, NULL, 5, NULL, 1);
    
    ESP_LOGI(TAG, "Clock display started - shows time counting up from 12:00:00");
}