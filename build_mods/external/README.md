1. cp -r AndroidAuto GmsCore Phonesky /src/$WORKDIR/external/

2. Add the following to `build/make/target/product/handheld_system.mk`
    ```
    PRODUCT_PACKAGES += \
        ...
        AndroidAuto \
        Phonesky \
        GmsCore \
    ```
