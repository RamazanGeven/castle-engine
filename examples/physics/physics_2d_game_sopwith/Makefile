# This Makefile uses castle-engine build tool for most operations.
# See https://github.com/castle-engine/castle-engine/wiki/Build-Tool .

.PHONY: standalone
standalone:
	castle-engine compile $(CASTLE_ENGINE_TOOL_OPTIONS)

.PHONY: clean
clean:
	castle-engine clean

.PHONY: android
android:
	castle-engine package --target=android
	castle-engine install --target=android
	castle-engine run --target=android

.PHONY: ios
ios:
	castle-engine package --target=iOS --fast
