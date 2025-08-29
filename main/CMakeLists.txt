# Register the app as an IDF component with C sources
idf_component_register(
    SRCS "app_main.c"
    PRIV_INCLUDE_DIRS "."
    REQUIRES 
        driver 
        esp_lcd 
        esp_lcd_touch 
        fatfs 
        sdmmc 
        espressif__avi_player
        freertos
)