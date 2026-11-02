.PHONY: build app run install clean

build:
	swift build -c release

app:
	./scripts/build-app.sh

run: app
	open dist/CallScribe.app

install: app
	rm -rf /Applications/CallScribe.app
	cp -R dist/CallScribe.app /Applications/
	open /Applications/CallScribe.app

clean:
	swift package clean
	rm -rf dist .build
