FROM amazon/aws-cli:latest
# The amazon/aws-cli image sets ENTRYPOINT=["/usr/local/bin/aws"], which
# prevents Nextflow from running shell scripts. Clear it so bash is usable.
# procps-ng provides `ps`, required by Nextflow for task metrics collection.
RUN dnf install -y procps-ng && dnf clean all
ENTRYPOINT []
CMD ["/bin/sh"]
