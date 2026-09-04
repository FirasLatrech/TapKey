.PHONY: app run test clean

app:
	sh scripts/build-app.sh

run: app
	open dist/TapKey.app

test:
	swift test

clean:
	swift package clean
