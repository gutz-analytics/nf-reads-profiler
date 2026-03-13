#!/usr/bin/env python3
"""
Config validation tests for nf-reads-profiler.

Validates that cost optimization fixes are properly applied across all
configuration files and process definitions. These tests verify config
correctness without requiring Nextflow execution.

Usage:
    python tests/scripts/test_config_validation.py
"""

import os
import re
import sys
import json

# Resolve project root
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
PROJECT_ROOT = os.path.abspath(os.path.join(SCRIPT_DIR, '..', '..'))

PASS = 0
FAIL = 0
WARN = 0


def check(condition, name, detail=""):
    """Record a test result."""
    global PASS, FAIL
    if condition:
        PASS += 1
        print(f"  PASS: {name}")
    else:
        FAIL += 1
        print(f"  FAIL: {name}")
        if detail:
            print(f"        {detail}")


def warn(condition, name, detail=""):
    """Record a warning (non-fatal)."""
    global WARN
    if not condition:
        WARN += 1
        print(f"  WARN: {name}")
        if detail:
            print(f"        {detail}")


def read_file(rel_path):
    """Read a file relative to project root."""
    path = os.path.join(PROJECT_ROOT, rel_path)
    with open(path, 'r') as f:
        return f.read()


# =============================================================================
# TEST GROUP 1: P0 — output_exists() is wired into profile_function
# =============================================================================
def test_output_exists_wired():
    print("\n[1] P0: output_exists() wired into profile_function")
    main = read_file('main.nf')

    # ch_filtered_reads must be used to build the HUMAnN input (not merged_reads directly)
    # With reuse_metaphlan_profile support, the call is profile_function(ch_humann_input)
    # where ch_humann_input is built from ch_filtered_reads
    check(
        'profile_function(ch_humann_input)' in main and 'ch_filtered_reads' in main,
        "profile_function receives filtered reads via ch_humann_input (built from ch_filtered_reads)",
        "Expected: ch_filtered_reads used to build ch_humann_input for profile_function"
    )

    # output_exists must check HUMAnN4 file naming convention
    check(
        '_2_genefamilies.tsv' in main,
        "output_exists() checks HUMAnN4 naming (_2_genefamilies.tsv)",
        "Old naming was _genefamilies.tsv without prefix number"
    )
    check(
        '_3_reactions.tsv' in main,
        "output_exists() checks _3_reactions.tsv"
    )
    check(
        '_4_pathabundance.tsv' in main,
        "output_exists() checks _4_pathabundance.tsv"
    )

    # Old dead reference should not exist
    check(
        'profile_function(merged_reads)' not in main,
        "No direct profile_function(merged_reads) call remains"
    )


# =============================================================================
# TEST GROUP 2: P0 — Trace file configuration
# =============================================================================
def test_trace_config():
    print("\n[2] P0: Trace file enabled for cost analysis")
    config = read_file('nextflow.config')

    check(
        'trace {' in config or 'trace{' in config,
        "trace block exists in nextflow.config"
    )
    check(
        'trace.txt' in config,
        "trace outputs to trace.txt"
    )

    # Check for essential fields
    for field in ['%cpu', 'peak_rss', 'realtime', 'memory', 'queue']:
        check(
            field in config,
            f"trace includes '{field}' field"
        )

    # Verify test profile disables trace (not needed for CI)
    test_config = read_file('conf/test.config')
    check(
        'trace.enabled = false' in test_config,
        "test profile disables trace (avoids test overhead)"
    )


# =============================================================================
# TEST GROUP 3: P1 — resourceLimits in all production profiles
# =============================================================================
def test_resource_limits():
    print("\n[3] P1: resourceLimits caps prevent runaway retries")

    for profile_name, path in [('azure', 'conf/azurebatch.config'), ('aws', 'conf/aws_batch.config')]:
        config = read_file(path)
        check(
            'resourceLimits' in config,
            f"{profile_name}: resourceLimits block exists"
        )
        # Verify it contains cpus, memory, time
        # Use regex to check within resourceLimits block
        check(
            re.search(r'resourceLimits\s*=\s*\[.*cpus', config, re.DOTALL) is not None,
            f"{profile_name}: resourceLimits includes cpus cap"
        )
        check(
            re.search(r'resourceLimits\s*=\s*\[.*memory', config, re.DOTALL) is not None,
            f"{profile_name}: resourceLimits includes memory cap"
        )


# =============================================================================
# TEST GROUP 4: P1 — Azure pool maxVmCount caps
# =============================================================================
def test_pool_caps():
    print("\n[4] P1: Azure pool maxVmCount reduced from 500")
    config = read_file('conf/azurebatch.config')

    # Extract all maxVmCount values
    max_counts = re.findall(r'maxVmCount\s*=\s*(\d+)', config)
    max_counts_int = [int(x) for x in max_counts]

    check(
        len(max_counts_int) > 0,
        "Found maxVmCount definitions in Azure config"
    )

    # General pools should not be 500
    general_pools_over_200 = sum(1 for x in max_counts_int if x > 200)
    check(
        general_pools_over_200 == 0,
        f"No pools exceed maxVmCount=200 (found {general_pools_over_200} over 200)",
        f"Values: {max_counts_int}"
    )


# =============================================================================
# TEST GROUP 5: P2 — copyToolInstallMode = 'node'
# =============================================================================
def test_copy_tool_mode():
    print("\n[5] P2: copyToolInstallMode set to 'node' (not 'task')")
    config = read_file('conf/azurebatch.config')

    check(
        "'node'" in config and 'copyToolInstallMode' in config,
        "copyToolInstallMode = 'node' in Azure config"
    )
    check(
        "copyToolInstallMode     = 'task'" not in config,
        "copyToolInstallMode is NOT 'task'"
    )


# =============================================================================
# TEST GROUP 6: P2 — Azure right-sizing for lightweight processes
# =============================================================================
def test_azure_rightsizing():
    print("\n[6] P2: Azure config has explicit overrides for lightweight processes")
    config = read_file('conf/azurebatch.config')

    for process_name in ['count_reads', 'convert_tables_to_biom', 'combine_humann_taxonomy_tables', 'get_software_versions']:
        check(
            process_name in config,
            f"Azure config has withName override for '{process_name}'"
        )

    # count_reads should NOT use 32GB
    # Find the count_reads block and check memory
    count_reads_match = re.search(
        r"withName:\s*'count_reads'\s*\{([^}]+)\}",
        config, re.DOTALL
    )
    if count_reads_match:
        block = count_reads_match.group(1)
        check(
            '32 GB' not in block and '32.GB' not in block,
            "count_reads does NOT use 32 GB memory"
        )
        check(
            '8 GB' in block or '8.GB' in block,
            "count_reads uses 8 GB or less"
        )


# =============================================================================
# TEST GROUP 7: P2 — clean_reads removes intermediate files
# =============================================================================
def test_clean_reads_cleanup():
    print("\n[7] P2: clean_reads removes intermediate R1/R2 after concatenation")
    house_keeping = read_file('modules/house_keeping.nf')

    check(
        'rm -f out.R1.fq.gz out.R2.fq.gz' in house_keeping,
        "clean_reads removes out.R1.fq.gz and out.R2.fq.gz after cat"
    )


# =============================================================================
# TEST GROUP 8: P3 — Kraken CPU right-sizing on Azure
# =============================================================================
def test_kraken_cpu():
    print("\n[8] P3: Kraken2 CPU allocation reduced (memory-I/O bound)")
    config = read_file('conf/azurebatch.config')

    # Match the kraken block — use greedy match since block contains nested { }
    kraken_match = re.search(
        r"withLabel:\s*'kraken'\s*\{(.+?)\n\s*\}",
        config, re.DOTALL
    )
    if kraken_match:
        block = kraken_match.group(1)
        cpu_match = re.search(r'cpus\s*=\s*(\d+)', block)
        if cpu_match:
            cpus = int(cpu_match.group(1))
            check(
                cpus <= 32,
                f"Kraken2 uses {cpus} CPUs (was 64, should be <=32)"
            )
        else:
            check(False, "Could not parse cpus from kraken block")
    else:
        check(False, "Could not find withLabel: 'kraken' block")


# =============================================================================
# TEST GROUP 9: P3 — No orphaned labels
# =============================================================================
def test_no_orphaned_labels():
    print("\n[9] P3: No orphaned process labels")

    # Collect all labels used in process definitions
    labels_used = set()
    for nf_file in ['modules/data_handling.nf', 'modules/house_keeping.nf',
                     'modules/community_characterisation.nf', 'subworkflows/quant.nf']:
        content = read_file(nf_file)
        for match in re.finditer(r"label\s+['\"](\w+)['\"]", content):
            labels_used.add(match.group(1))

    # Collect all labels configured in production configs
    labels_configured = set()
    for config_file in ['conf/azurebatch.config', 'conf/aws_batch.config']:
        content = read_file(config_file)
        for match in re.finditer(r"withLabel:\s*['\"]?(\w+)['\"]?\s*\{", content):
            labels_configured.add(match.group(1))

    orphaned = labels_used - labels_configured
    # Filter out labels that have withName overrides instead
    check(
        'process_low' not in labels_used and 'process_medium' not in labels_used,
        "No nf-core-style orphaned labels (process_low, process_medium) in process definitions",
        f"Labels in use: {labels_used}"
    )


# =============================================================================
# TEST GROUP 10: P3 — publishDir modes on all MEDI processes
# =============================================================================
def test_publishdir_modes():
    print("\n[10] P3: All publishDir directives have explicit mode for cloud storage")
    quant = read_file('subworkflows/quant.nf')

    # Find all publishDir lines
    pub_lines = re.findall(r'publishDir\s+.*', quant)

    missing_mode = []
    for line in pub_lines:
        if 'mode' not in line:
            missing_mode.append(line.strip())

    check(
        len(missing_mode) == 0,
        f"All {len(pub_lines)} publishDir directives have explicit mode",
        f"Missing mode: {missing_mode}" if missing_mode else ""
    )


# =============================================================================
# TEST GROUP 11: P3 — No double fastp when MEDI enabled
# =============================================================================
def test_no_double_fastp():
    print("\n[11] P3: MEDI uses pre-cleaned reads (no double fastp)")
    main = read_file('main.nf')

    check(
        'clean_reads.out.reads_cleaned' in main and 'MEDI' not in main.split('clean_reads.out.reads_cleaned')[0][-200:],
        "MEDI receives clean_reads output (not raw reads)"
    )

    # Check MEDI subworkflow accepts precleaned parameter
    quant = read_file('subworkflows/quant.nf')
    check(
        'precleaned' in quant,
        "MEDI_QUANT workflow accepts 'precleaned' parameter"
    )
    check(
        'if (precleaned)' in quant or 'if(precleaned)' in quant,
        "MEDI_QUANT conditionally skips preprocess when precleaned=true"
    )


# =============================================================================
# TEST GROUP 12: afterScript cleanup directives
# =============================================================================
def test_afterscript_cleanup():
    print("\n[12] Intermediate file cleanup via afterScript")
    cc = read_file('modules/community_characterisation.nf')

    check(
        'afterScript' in cc and 'profile_taxa' in cc,
        "profile_taxa has afterScript for bowtie2 cleanup"
    )
    check(
        'afterScript' in cc and '_humann_temp' in cc,
        "profile_function has afterScript for HUMAnN temp cleanup"
    )


# =============================================================================
# TEST GROUP 13: Error strategy correctness
# =============================================================================
def test_error_strategies():
    print("\n[13] Error strategy distinguishes infrastructure vs software failures")

    for name, path in [('azure', 'conf/azurebatch.config'), ('aws', 'conf/aws_batch.config')]:
        config = read_file(path)

        check(
            '137' in config and '143' in config and '139' in config,
            f"{name}: errorStrategy checks exit codes 137, 143, 139"
        )
        check(
            "'finished'" in config or '"finished"' in config,
            f"{name}: errorStrategy returns 'finished' on success"
        )
        check(
            "'ignore'" in config or '"ignore"' in config,
            f"{name}: errorStrategy returns 'ignore' after max retries"
        )


# =============================================================================
# TEST GROUP 14: AWS-specific optimizations
# =============================================================================
def test_aws_optimizations():
    print("\n[14] AWS-specific cost optimizations")
    config = read_file('conf/aws_batch.config')

    check(
        'ondemand-queue' in config,
        "AWS config has dedicated on-demand queue for HUMAnN"
    )
    check(
        'spot-highmem-queue' in config,
        "AWS config has dedicated high-memory spot queue for Kraken"
    )
    check(
        'INTELLIGENT_TIERING' in config,
        "AWS uses S3 Intelligent-Tiering for work directory"
    )
    check(
        'maxSpotAttempts' in config,
        "AWS config sets maxSpotAttempts for native spot retry"
    )


# =============================================================================
# TEST GROUP 15: Consistency checks across configs
# =============================================================================
def test_cross_config_consistency():
    print("\n[15] Cross-config consistency")
    azure = read_file('conf/azurebatch.config')
    aws = read_file('conf/aws_batch.config')

    # Both should have lenient caching
    check("'lenient'" in azure, "Azure uses lenient cache")
    check("'lenient'" in aws, "AWS uses lenient cache")

    # Both should have cleanup = true
    check('cleanup = true' in azure, "Azure has cleanup = true")
    check('cleanup = true' in aws, "AWS has cleanup = true")

    # MULTIQC should be right-sized in both
    for name, config in [('azure', azure), ('aws', aws)]:
        mqc_match = re.search(r"withName:\s*'?MULTIQC'?\s*\{([^}]+)\}", config, re.DOTALL)
        if mqc_match:
            block = mqc_match.group(1)
            check(
                '4 GB' in block or '4.GB' in block,
                f"{name}: MULTIQC uses 4 GB memory (not 512 GB)"
            )


# =============================================================================
# TEST GROUP 16: HUMAnN spot toggle
# =============================================================================
def test_humann_spot_toggle():
    print("\n[16] HUMAnN spot instance toggle")
    config = read_file('nextflow.config')

    check(
        'humann_spot' in config,
        "humann_spot parameter defined in nextflow.config"
    )
    check(
        'humann_spot = false' in config,
        "humann_spot defaults to false (safe default)"
    )

    aws = read_file('conf/aws_batch.config')
    check(
        'params.humann_spot' in aws,
        "AWS config references params.humann_spot for queue selection"
    )
    check(
        "spot-queue" in aws and "ondemand-queue" in aws,
        "AWS config supports both spot and on-demand queues for HUMAnN"
    )


# =============================================================================
# TEST GROUP 17: bypass_translated_search toggle
# =============================================================================
def test_bypass_translated_search():
    print("\n[17] HUMAnN bypass-translated-search optimization")
    config = read_file('nextflow.config')

    check(
        'bypass_translated_search' in config,
        "bypass_translated_search parameter defined"
    )
    check(
        'bypass_translated_search = false' in config,
        "bypass_translated_search defaults to false (full analysis)"
    )

    cc = read_file('modules/community_characterisation.nf')
    check(
        'bypass_translated_search' in cc and 'bypass-translated-search' in cc,
        "profile_function uses bypass_translated_search parameter"
    )


# =============================================================================
# TEST GROUP 18: submitRateLimit on all cloud profiles
# =============================================================================
def test_submit_rate_limits():
    print("\n[18] API rate limiting on cloud profiles")

    for name, path in [('azure', 'conf/azurebatch.config'), ('aws', 'conf/aws_batch.config')]:
        config = read_file(path)
        check(
            'submitRateLimit' in config,
            f"{name}: submitRateLimit configured to prevent API throttling"
        )


# =============================================================================
# TEST GROUP 19: medi_unmapped_only — HUMAnN-unmapped reads to MEDI
# =============================================================================
def test_medi_unmapped_only():
    print("\n[19] MEDI unmapped-only mode (feed HUMAnN-unaligned reads to MEDI)")
    config = read_file('nextflow.config')
    main = read_file('main.nf')
    cc = read_file('modules/community_characterisation.nf')

    # Parameter exists and defaults to false
    check(
        'medi_unmapped_only' in config,
        "medi_unmapped_only parameter defined in nextflow.config"
    )
    check(
        'medi_unmapped_only = false' in config,
        "medi_unmapped_only defaults to false (safe default, no serial dependency)"
    )

    # profile_function emits unaligned reads as optional output
    check(
        'unaligned_reads' in cc,
        "profile_function has 'unaligned_reads' emit channel"
    )
    check(
        'optional: true' in cc and 'unaligned' in cc,
        "unaligned_reads output is marked optional (not all samples produce it)"
    )

    # Script preserves unaligned reads from HUMAnN temp dir
    check(
        'diamond_unaligned.fa' in cc,
        "Script checks for diamond_unaligned.fa (fully unmapped reads)"
    )
    check(
        'bowtie2_unaligned.fa' in cc,
        "Script falls back to bowtie2_unaligned.fa (for bypass_translated_search mode)"
    )

    # FASTA to FASTQ conversion for pipeline consistency
    check(
        'fastq.gz' in cc and 'unaligned' in cc,
        "Unaligned reads converted to gzipped FASTQ for pipeline consistency"
    )

    # main.nf routes unmapped reads when flag is set
    check(
        'medi_unmapped_only' in main,
        "main.nf references medi_unmapped_only parameter"
    )
    check(
        'profile_function.out.unaligned_reads' in main,
        "main.nf uses profile_function unaligned_reads channel for MEDI input"
    )

    # Fallback: samples with existing HUMAnN output get all cleaned reads
    check(
        'output_exists(meta)' in main and 'ch_skipped_samples' in main,
        "Skipped samples (existing HUMAnN output) fall back to all cleaned reads"
    )

    # Conditional: only activates when both medi_unmapped_only AND HUMAnN runs
    check(
        'params.medi_unmapped_only && !params.skipHumann' in main
        or 'params.medi_unmapped_only && ! params.skipHumann' in main,
        "medi_unmapped_only only activates when HUMAnN is enabled (skipHumann=false)"
    )


# =============================================================================
# TEST GROUP 20: reuse_metaphlan_profile — Skip HUMAnN's internal MetaPhlAn
# =============================================================================
def test_reuse_metaphlan_profile():
    print("\n[20] Reuse MetaPhlAn profile in HUMAnN (skip duplicate MetaPhlAn)")
    config = read_file('nextflow.config')
    main = read_file('main.nf')
    cc = read_file('modules/community_characterisation.nf')

    # Parameter exists and defaults to false
    check(
        'reuse_metaphlan_profile' in config,
        "reuse_metaphlan_profile parameter defined in nextflow.config"
    )
    check(
        'reuse_metaphlan_profile = false' in config,
        "reuse_metaphlan_profile defaults to false (safe default, no DB version assumption)"
    )

    # profile_taxa emits a TSV profile for HUMAnN
    check(
        'metaphlan_tsv' in cc,
        "profile_taxa has 'metaphlan_tsv' emit channel for TSV output"
    )
    check(
        'metaphlan_profile.tsv' in cc,
        "profile_taxa produces *_metaphlan_profile.tsv file"
    )

    # profile_function accepts a taxonomy profile input
    check(
        'tax_profile' in cc,
        "profile_function accepts tax_profile input"
    )
    check(
        '--taxonomic-profile' in cc,
        "profile_function uses HUMAnN --taxonomic-profile flag"
    )
    check(
        'NO_TAXONOMY_PROFILE' in cc,
        "Sentinel file NO_TAXONOMY_PROFILE used when no pre-computed profile"
    )

    # main.nf wires profile_taxa output into profile_function
    check(
        'profile_taxa.out.metaphlan_tsv' in main,
        "main.nf joins profile_taxa TSV output with filtered reads for HUMAnN"
    )
    check(
        'reuse_metaphlan_profile' in main,
        "main.nf conditionally routes based on reuse_metaphlan_profile flag"
    )
    check(
        'NO_TAXONOMY_PROFILE' in main,
        "main.nf uses NO_TAXONOMY_PROFILE sentinel when flag is disabled"
    )

    # Single MetaPhlAn run: TSV + biom convert (not two separate MetaPhlAn runs)
    check(
        'biom convert' in cc and 'metaphlan_profile.tsv' in cc,
        "profile_taxa converts TSV to biom (single MetaPhlAn run, not two)"
    )


# =============================================================================
# TEST GROUP 21: medi_spot — MEDI Kraken2 on spot instances
# =============================================================================
def test_medi_spot():
    print("\n[21] MEDI spot instances (86% cheaper Kraken2)")
    config = read_file('nextflow.config')
    azure = read_file('conf/azurebatch.config')

    # Parameter exists and defaults to false
    check(
        'medi_spot' in config,
        "medi_spot parameter defined in nextflow.config"
    )
    check(
        'medi_spot = false' in config,
        "medi_spot defaults to false (safe default, dedicated nodes)"
    )

    # Azure config has spot-enabled kraken ramdisk pool
    check(
        'kraken_ramdisk_spot' in azure,
        "Azure config has kraken_ramdisk_spot pool definition"
    )

    # Spot pool has lowPriority = true
    # Use a broader match that handles nested { } in startTask block
    # Skip the first occurrence (queue selector string) to find the pool definition
    first_occurrence = azure.find('kraken_ramdisk_spot')
    spot_pool_start = azure.find('kraken_ramdisk_spot {', first_occurrence)
    if spot_pool_start == -1:
        # Try finding it after the pools { block
        spot_pool_start = azure.find('kraken_ramdisk_spot', azure.find('pools'))
        spot_pool_start = azure.find('kraken_ramdisk_spot {', spot_pool_start) if spot_pool_start != -1 else -1
    if spot_pool_start != -1:
        # Find the pool block by counting braces
        block_start = azure.index('{', spot_pool_start)
        depth = 0
        block_end = block_start
        for i, ch in enumerate(azure[block_start:], block_start):
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth -= 1
                if depth == 0:
                    block_end = i
                    break
        block = azure[block_start:block_end+1]
        spot_pool_match = True
    else:
        block = ''
        spot_pool_match = False

    if spot_pool_match:
        check(
            'lowPriority = true' in block,
            "kraken_ramdisk_spot pool uses lowPriority (spot) instances"
        )
        check(
            'Standard_M64ls' in block,
            "kraken_ramdisk_spot uses same VM type (Standard_M64ls) as dedicated pool"
        )
    else:
        check(False, "Could not parse kraken_ramdisk_spot pool block")

    # Kraken label dynamically selects pool based on medi_spot
    check(
        'params.medi_spot' in azure,
        "Azure kraken label references params.medi_spot for queue selection"
    )
    check(
        'kraken_ramdisk_spot' in azure and 'kraken_ramdisk' in azure,
        "Azure config supports both spot and dedicated kraken pools"
    )


# =============================================================================
# MAIN
# =============================================================================
if __name__ == '__main__':
    print("=" * 70)
    print("nf-reads-profiler Config Validation Test Suite")
    print("=" * 70)

    test_output_exists_wired()
    test_trace_config()
    test_resource_limits()
    test_pool_caps()
    test_copy_tool_mode()
    test_azure_rightsizing()
    test_clean_reads_cleanup()
    test_kraken_cpu()
    test_no_orphaned_labels()
    test_publishdir_modes()
    test_no_double_fastp()
    test_afterscript_cleanup()
    test_error_strategies()
    test_aws_optimizations()
    test_cross_config_consistency()
    test_humann_spot_toggle()
    test_bypass_translated_search()
    test_submit_rate_limits()
    test_medi_unmapped_only()
    test_reuse_metaphlan_profile()
    test_medi_spot()

    print("\n" + "=" * 70)
    print(f"RESULTS: {PASS} passed, {FAIL} failed, {WARN} warnings")
    print("=" * 70)

    if FAIL > 0:
        sys.exit(1)
    else:
        print("\nAll config validation tests passed!")
        sys.exit(0)
