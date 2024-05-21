#!/bin/bash
############


set +e
set -u
set -o pipefail

CONTIGTYPE="normal"
THREADS=1
SAMPLENAME=""
ALLELE_FREQ=0.15
READ_DEPTH=10
ALLELE_COUNT=4
PIPERDIR="."
OUTDIR_BASE="../HybPhaser"
NAMELIST="not a file"
CLEANUP="FALSE"
BBMAP="FALSE"
MINID=0.95

while getopts 'ict:s:a:f:d:p:o:n:b:m:' OPTION; do
	case "$OPTION" in

		i)
			CONTIGTYPE="ISC"
			;;

		c)
			CLEANUP="TRUE"
			;;

		t)
			THREADS=$OPTARG
			;;

		s)
			SAMPLENAME=$OPTARG
			;;

		f)
			ALLELE_FREQ=$OPTARG
			;;

		a)
			ALLELE_COUNT=$OPTARG
			;;

		d)
			READ_DEPTH=$OPTARG
			;;

		p)
			PIPERDIR=$OPTARG
			;;

		o)
			OUTDIR_BASE=$OPTARG
			;;

		n)
			NAMELIST=$OPTARG
			;;

		b)
			BBMAP="TRUE"
			;;

		m)
			MINID=$OPTARG
			;;

		?)

		echo "This script is used to generate consensus sequences by remapping reads to de novo contigs generated by HybPiper. It is part of the HybPhaser workflow and has to be executed first. 
		Usage: generate_consensus_sequences.sh [options]
		Options:
		General:
			-s	<Name of sample> (if not providing a namelist)
			-n	<Namelist> (txt file with sample names, one per line)
			-p	<Path to HybPiper results folder> Default is current folder.
			-o	<Path to output folder>  (will be created, if it doesnt exist). Default is ../HybPhaser
			-i	-intronerated: If set, intronerate_supercontigs are used in addition to normal contigs. 
			-c	-clean-up: If set, reads and mapping files are removed (.bam, .vcf.gz) doesnt work in parallel!
			-b	use BBMap to do the alignment, keeping alignments that are minimum 95% identical to the reference (default: use BWA)
			-m	the minimum read mapping identity if using BBMap (default: 0.95)
		Adjust consensus sequence generation:
			-d	Minimum coverage on site to be regarded for assigning ambiguity code.
				If read depth on that site is lower than chosen value, the site is not used for ambiguity code but the most frequent base is returned. Default is 10.
			-f	Minimum allele frequency regarded for assigning ambiguity code.
				If the alternative allele is less frequent than the chosen value, it is not included in ambiguity coding. Default is 0.15.
			-a	Minimum count of alleles to be regarded for assigning ambiguity code.
				If the alternative allele ocurrs less often than the chosen value, it is not included in ambiguity coding. Default is 4.
		" >&2

		exit 1
		;;
	esac
done
shift "$(($OPTIND -1))"


if [[ -f $NAMELIST ]]; then

	SAMPLES=$(<$NAMELIST)

elif [[ $SAMPLENAME != "" ]]; then

	SAMPLES=$SAMPLENAME

else

	echo "No sample name given or namelist file does not exist!"

fi


for SAMPLE in $SAMPLES
do
	SECONDS=0

	#collecting reads and contigs from each sample
	echo Collecting read and contigs files for $SAMPLE

	OUTDIR=$OUTDIR_BASE"/01_data"

		# check if any assembly has been done, by checking if genes.seq exists in HybPiper sample folder

	if [[ ! -f "$PIPERDIR/$SAMPLE/genes_with_seqs.txt" ]]; then 

		echo !!! Could not find HybPiper output files for $SAMPLE

	else 

		mkdir -p "$OUTDIR/$SAMPLE/reads"

		cp $PIPERDIR/$SAMPLE/*/*_unpaired.fasta $OUTDIR/$SAMPLE/reads/ 2> /dev/null
		cp $PIPERDIR/$SAMPLE/*/*_interleaved.fasta $OUTDIR/$SAMPLE/reads/ 2> /dev/null

		if compgen -G $OUTDIR/$SAMPLE/reads/*_interleaved.fasta > /dev/null; then
			for i in $OUTDIR/$SAMPLE/reads/*_interleaved.fasta
			do 
				cat $i ${i/_interleaved.fasta/_unpaired.fasta} > ${i/_interleaved.fasta/_combined.fasta} 2> /dev/null
				rm $i ${i/_interleaved.fasta/_unpaired.fasta} 2> /dev/null
			done
		fi


		if [[ $CONTIGTYPE == "normal" ]]; then
			mkdir -p $OUTDIR/$SAMPLE/contigs
			cp $PIPERDIR/$SAMPLE/*/*/sequences/FNA/*.FNA $OUTDIR/$SAMPLE/contigs/ 2> /dev/null

			# adding gene name into the fasta files ">sample-gene"
			for i in $OUTDIR/$SAMPLE/contigs/*.FNA
			do
				FILE=${i/*\/contigs\//}
				GENE=${FILE/.FNA/}
				sed -i "s/ .*//" $i
				sed -i "s/\(>.*\)/\1-$GENE/" $i
			done

			# renaming .FNA to .fasta for consistency
			for f in $OUTDIR/$SAMPLE/contigs/*.FNA; do mv "$f" "${f/.FNA/.fasta}"; done

			CONTIGPATH="$OUTDIR/$SAMPLE/contigs"
			mkdir -p "$OUTDIR/$SAMPLE/consensus"
		else
			# when intronerate is selected
			mkdir -p $OUTDIR/$SAMPLE/intronerated_contigs
			cp $PIPERDIR/$SAMPLE/*/*/sequences/intron/*_supercontig.fasta $OUTDIR/$SAMPLE/intronerated_contigs/ 2> /dev/null
			for f in $OUTDIR/$SAMPLE/intronerated_contigs/*.*
			do
				sed -i "s/ .*//" $f
				awk '{if(NR==1) {print $0} else {if($0 ~ /^>/) {print "\n"$0} else {printf $0}}}' "$f" > "${f/_supercontig/_intronerated}"
				rm "$f" -f
				echo "" >> "${f/_supercontig/_intronerated}"
			done
			CONTIGPATH="$OUTDIR/$SAMPLE/intronerated_contigs"
			mkdir -p "$OUTDIR/$SAMPLE/intronerated_consensus"
		fi


		mkdir -p "$OUTDIR/$SAMPLE/mapping_files"
		
		# start remapping reads to contigs

			makecons () {
				local CONTIG=$1
				FILE=${CONTIG/*\/*contigs\//}
				GENE=${FILE/.fasta/}

				echo -e '\e[1A\e[K'Generating consensus sequences for $SAMPLE - $GENE

				if [[ $CONTIGTYPE == "normal" ]]; then 
					CONSENSUS=$OUTDIR/$SAMPLE/consensus/$GENE".fasta"
					BAM=$OUTDIR/$SAMPLE/mapping_files/$GENE".bam"
					VCFZ=$OUTDIR/$SAMPLE/mapping_files/$GENE".vcf.gz"
				else
					GENE=${GENE/_intronerated/}	
					CONSENSUS=$OUTDIR/$SAMPLE/intronerated_consensus/$GENE"_intronerated.fasta"
					BAM=$OUTDIR/$SAMPLE/mapping_files/$GENE"_intronerated.bam"
					VCFZ=$OUTDIR/$SAMPLE/mapping_files/$GENE"_intronerated.vcf.gz"
				fi


				# checking for paired-end reads
				if [[ -f $OUTDIR/$SAMPLE/reads/$GENE"_combined.fasta" ]];then
					READS=$OUTDIR/$SAMPLE/reads/$GENE"_combined.fasta"
					READTYPE="PE"
				else
					READS=$OUTDIR/$SAMPLE/reads/$GENE"_unpaired.fasta"
					READTYPE="SE"
				fi


				if [ "$BBMAP" = "TRUE" ]; then
					mkdir temp_"$GENE" && cd temp_"$GENE"
					bbmap.sh ref=../"$CONTIG" in=../"$READS" outm=map.sam nodisk bs=bs.sh minid="$MINID" \
						ambiguous="random" trimreaddescriptions="t" threads=1 > /dev/null 2>&1
					bash bs.sh > /dev/null 2>&1
					cp map_sorted.bam ../$BAM
					cd .. && rm -r temp_"$GENE"
				else
					bwa index $CONTIG 2> /dev/null

					if [ "$READTYPE" = "SE" ];then 
						bwa mem $CONTIG $READS -t 1 -v 1 2> /dev/null | samtools sort > $BAM
					else 
						bwa mem -p $CONTIG $READS -t 1 -v 1 2> /dev/null | samtools sort > $BAM
					fi
				fi

				bcftools mpileup -I -Ov -f $CONTIG $BAM 2> /dev/null | bcftools call -mv -A -Oz -o  $VCFZ 2> /dev/null
				bcftools index -f --threads 1 $VCFZ 2> /dev/null 
				bcftools consensus -I -i "(DP4[2]+DP4[3])/(DP4[0]+DP4[1]+DP4[2]+DP4[3]) >= $ALLELE_FREQ && (DP4[0]+DP4[1]+DP4[2]+DP4[3]) >= $READ_DEPTH && (DP4[2]+DP4[3]) >= $ALLELE_COUNT " -f $CONTIG $VCFZ 2> /dev/null | awk '{if(NR==1) {print $0} else {if($0 ~ /^>/) {print "\n"$0} else {printf $0}}}' > $CONSENSUS
				echo "" >> $CONSENSUS
				rm $CONTIG.* 2> /dev/null 
				rm $VCFZ".csi" 2> /dev/null 

				# optional clean-up step: remove folders with mapping stats and reads
				if [[ $CLEANUP == "TRUE" ]]; then 
					rm $VCFZ $READS $BAM
				fi
			}


		max_jobs="$THREADS"
		current_jobs=0
		for CONTIG in $CONTIGPATH/*.fasta; do
				((current_jobs >= max_jobs)) && wait -n 
				makecons "$CONTIG" & 
				((++current_jobs))
		done
		wait

		DURATION_SAMPLE=$SECONDS
		echo -e '\e[1A\e[K'Generated consensus for $SAMPLE in $(($DURATION_SAMPLE / 60)) minutes and $(($DURATION_SAMPLE % 60)) seconds.

	fi
done
