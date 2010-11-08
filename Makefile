RIAK_TAG		= $(shell hg identify -t)
export ICU_CFLAGS=$(shell icu-config --cppflags-searchpath) \
                  $(shell icu-config --cflags)
export ICU_LDFLAGS=$(shell icu-config --ldflags) \
                   $(shell icu-config --ldflags-icuio)

.PHONY: rel stagedevrel deps

all: deps compile

compile:
	./rebar compile
	make -C apps/qilr/java_src

deps:
	./rebar get-deps

clean:
	./rebar clean
	make -C apps/qilr/java_src clean

distclean: clean devclean relclean ballclean
	./rebar delete-deps

test:
	./rebar skip_deps=true eunit

##
## Release targets
##
rel: deps
	make -C apps/qilr/java_src
	./rebar compile generate

rellink:
	$(foreach app,$(wildcard apps/*), rm -rf rel/riaksearch/lib/$(shell basename $(app))* && ln -sf $(abspath $(app)) rel/riaksearch/lib;)
	$(foreach dep,$(wildcard deps/*), rm -rf rel/riaksearch/lib/$(shell basename $(dep))* && ln -sf $(abspath $(dep)) rel/riaksearch/lib;)

relclean:
	rm -rf rel/riaksearch

##
## Developer targets
##
stagedevrel: dev1 dev2 dev3
	$(foreach dev,$^,\
	  $(foreach dep,$(wildcard deps/*), rm -rf dev/$(dev)/lib/$(shell basename $(dep))-* && ln -sf $(abspath $(dep)) dev/$(dev)/lib;))

devrel: dev1 dev2 dev3

dev1 dev2 dev3:
	mkdir -p dev
	(cd rel && ../rebar generate target_dir=../dev/$@ overlay_vars=vars/$@_vars.config)

devclean: clean
	rm -rf dev

stage : rel
	$(foreach app,$(wildcard apps/*), rm -rf rel/riaksearch/lib/$(shell basename $(app))-* && ln -sf $(abspath $(app)) rel/riaksearch/lib;)
	$(foreach dep,$(wildcard deps/*), rm -rf rel/riaksearch/lib/$(shell basename $(dep))-* && ln -sf $(abspath $(dep)) rel/riaksearch/lib;)


##
## Doc targets
##
docs:
	./rebar skip_deps=true doc
	@cp -R apps/luke/doc doc/luke
	@cp -R apps/riak_core/doc doc/riak_core
	@cp -R apps/riak_kv/doc doc/riak_kv

orgs: orgs-doc orgs-README

orgs-doc:
	@emacs -l orgbatch.el -batch --eval="(riak-export-doc-dir \"doc\" 'html)"

orgs-README:
	@emacs -l orgbatch.el -batch --eval="(riak-export-doc-file \"README.org\" 'ascii)"
	@mv README.txt README

APPS = kernel stdlib sasl erts ssl tools os_mon runtime_tools crypto inets \
	xmerl webtool snmp public_key mnesia eunit syntax_tools compiler
COMBO_PLT = $(HOME)/.riak_search_combo_dialyzer_plt


check_plt: compile
	dialyzer --check_plt --plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin apps/*/ebin

build_plt: compile
	dialyzer --build_plt --output_plt $(COMBO_PLT) --apps $(APPS) \
		deps/*/ebin apps/*/ebin

dialyzer: compile
	@echo
	@echo Use "'make check_plt'" to check PLT prior to using this target.
	@echo Use "'make build_plt'" to build PLT prior to using this target.
	@echo
	dialyzer -Wno_return --plt $(COMBO_PLT) deps/*/ebin apps/*/ebin | \
	    fgrep -v -f ./dialyzer.ignore-warnings

cleanplt:
	@echo 
	@echo "Are you sure?  It takes about 1/2 hour to re-build."
	@echo Deleting $(COMBO_PLT) in 5 seconds.
	@echo 
	sleep 5
	rm $(COMBO_PLT)

# Release tarball creation
# Generates a tarball that includes all the deps sources so no checkouts are necessary

distdir:
	$(if $(findstring tip,$(RIAK_TAG)),$(error "You can't generate a release tarball from tip"))
	mkdir distdir
	hg clone -u $(RIAK_TAG) . distdir/riak-clone
	cd distdir/riak-clone; \
	hg archive ../$(RIAK_TAG); \
	mkdir ../$(RIAK_TAG)/deps; \
	make deps; \
	for dep in deps/*; do cd $${dep} && hg archive ../../../$(RIAK_TAG)/$${dep}; cd ../..; done

dist $(RIAK_TAG).tar.gz: distdir
	cd distdir; \
	tar czf ../$(RIAK_TAG).tar.gz $(RIAK_TAG)

ballclean:
	rm -rf $(RIAK_TAG).tar.gz distdir
