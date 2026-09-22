.PHONY: build install verify clean
build:
	./scripts/build.sh

install: build
	open "outputs/Orkhon Code Installer.pkg"

verify:
	./scripts/verify.sh

clean:
	rm -rf .build work/build
