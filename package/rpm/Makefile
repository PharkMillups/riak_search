
DISTRO = $(shell head -1 /etc/redhat-release| awk \
           '{if ($$0 ~ /CentOS/) { print ".el5."} else { print "." }} ')

build: $(PKGERDIR)/SOURCES/$(APP)-$(REVISION).tar.gz rpmbuild
	@echo "DISTRO = $(DISTRO)"
	@echo "SEARCH_TAG = $(SEARCH_TAG)"
	@echo "REVISION = $(REVISION)"
	@echo "RELEASE  = $(RELEASE)"
	rpmbuild --define "_rpmfilename %%{NAME}-%%{VERSION}-%%{RELEASE}$(DISTRO)%%{ARCH}.rpm" \
		 --define '_topdir $(CURDIR)/rpmbuild' \
		 --define '_sourcedir $(CURDIR)/$(PKGERDIR)/SOURCES' \
		 --define '_specdir $(CURDIR)/$(PKGERDIR)/SPECS' \
		 --define '_rpmdir $(CURDIR)/packages' \
		 --define '_srcrpmdir $(CURDIR)/packages' \
		 --define "_revision $(REVISION)" \
		 --define "_repo $(REPO)" \
		 --define "_version $(PKG_VERSION)" \
		 --define "_release $(RELEASE)" \
		 -ba $(PKGERDIR)/SPECS/$(APP).spec

rpmbuild:
	@mkdir -p rpmbuild/BUILD
	@mkdir -p packages

# In case it doesn't exist because there aren't any patches to apply
$(PKGERDIR)/SOURCES:
	@mkdir -m 0755 -p $(PKGERDIR)/SOURCES

$(PKGERDIR)/SOURCES/$(APP)-$(REVISION).tar.gz:  $(APP)-$(REVISION).tar.gz \
						$(PKGERDIR)/SOURCES
	cp $(APP)-$(REVISION).tar.gz $(PKGERDIR)/SOURCES

$(PKGERDIR)/pkgclean:
	@echo
