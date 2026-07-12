APP := IFCQuickLook
DERIVED := build/dd
LSREGISTER := /System/Library/Frameworks/CoreServices.framework/Versions/Current/Frameworks/LaunchServices.framework/Versions/Current/Support/lsregister

.PHONY: gen build install test ql reset vendor release release-check

# web-ifc 静的ライブラリ（submodule → .webifc/{lib,include}）
.webifc/lib/libweb-ifc.a:
	git submodule update --init --recursive
	./scripts/build-webifc.sh

vendor: .webifc/lib/libweb-ifc.a

gen: vendor
	xcodegen generate

build: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Release \
		-derivedDataPath $(DERIVED) build

install: build
	-pkill -x $(APP)
	-$(LSREGISTER) -u $(DERIVED)/Build/Products/Release/$(APP).app
	rm -rf /Applications/$(APP).app
	ditto $(DERIVED)/Build/Products/Release/$(APP).app /Applications/$(APP).app
	$(LSREGISTER) -f -R -trusted /Applications/$(APP).app
	pluginkit -a /Applications/$(APP).app/Contents/PlugIns/IFCPreview.appex
	open /Applications/$(APP).app

test: gen
	xcodebuild -project $(APP).xcodeproj -scheme $(APP) -configuration Debug \
		-derivedDataPath $(DERIVED) -only-testing:IFCCoreTests test

ql:
	qlmanage -p Tests/Fixtures/minimal_wall.ifc

reset:
	qlmanage -r && qlmanage -r cache

release:
	bash scripts/release.sh

release-check:
	bash scripts/release.sh check
