FROM condaforge/miniforge3:latest

RUN mamba install -y -c conda-forge -c bioconda \
    "python>=3.8" \
    "nextflow>=23.10.0" \
    fastp \
    "kraken2==2.1.3" \
    prodigal \
    "multiqc>=1.28.0" \
    "typeguard<=4.4.0" \
    biopython \
    sourmash \
    pandas \
    r-base \
    r-data.table \
    r-reutils \
    r-r.utils \
    r-rcurl \
    r-magrittr \
    r-futile.logger \
    bioconductor-biostrings \
    taxonkit \
    "architeuthis>=0.4.0" \
    gxx \
    && mamba clean --all --yes

# Build Bracken v2.6.0 from source (no ARM build on bioconda)
RUN git clone --branch v2.6.0 --depth 1 https://github.com/jenniferlu717/Bracken.git /opt/bracken \
    && cd /opt/bracken \
    && bash install_bracken.sh

ENV PATH="/opt/bracken:${PATH}"

# Install MEDI pipeline scripts and compile kraken2-report from source
# (pre-built binary in repo is x86; Makefile recompiles for the target arch)
RUN git clone --branch 0.2.1 --depth 1 https://github.com/Gibbons-Lab/medi.git /opt/medi \
    && cd /opt/medi \
    && make repo \
    && make report \
    && cp                  bin/fixk2report.R            bin/quantify.R            bin/kraken2-report /usr/local/bin/ \
    && chmod +x /usr/local/bin/fixk2report.R /usr/local/bin/quantify.R /usr/local/bin/kraken2-report \
    && kraken2-report 2>&1 | grep -q "malformed taxonomy file"
