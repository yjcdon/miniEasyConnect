package resolve

import (
	"strings"

	"github.com/mythologyli/zju-connect/client"
)

type domainResourceEntry struct {
	domain    string
	resources []client.DomainResource
}

type domainResourceIndex struct {
	entries map[string]*domainResourceEntry
}

// newDomainResourceIndex stores one entry per policy suffix instead of one map per character.
func newDomainResourceIndex(resources client.DomainResources) *domainResourceIndex {
	index := &domainResourceIndex{entries: make(map[string]*domainResourceEntry, len(resources))}
	for domain, domainResources := range resources {
		normalized := normalizeHostname(domain)
		if strings.HasPrefix(normalized, "*.") {
			normalized = normalized[1:]
		}
		if normalized == "" {
			continue
		}
		entry := index.entries[normalized]
		if entry == nil {
			entry = &domainResourceEntry{domain: domain}
			index.entries[normalized] = entry
		}
		entry.resources = append(entry.resources, domainResources...)
	}
	return index
}

// Match checks label boundaries from most to least specific and preserves policy fallback order.
func (i *domainResourceIndex) Match(host string) (string, []client.DomainResource, bool) {
	if i == nil {
		return "", nil, false
	}
	var domain string
	var resources []client.DomainResource
	for pos := 0; pos < len(host); pos++ {
		if pos != 0 && host[pos] != '.' && host[pos-1] != '.' {
			continue
		}
		if entry := i.entries[host[pos:]]; entry != nil {
			if domain == "" {
				domain = entry.domain
			}
			resources = append(resources, entry.resources...)
		}
	}
	return domain, resources, domain != ""
}
