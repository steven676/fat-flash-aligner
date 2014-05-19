#
# Library routines for aligning FAT data area with SD card structure
#

# FAT filesystem parameters which are fixed for purposes of this script
NUM_FATS=2
MIN_RESERVED_SECTORS=12

# Integer division: $1/$2 with fractions always rounded up
div_round_up() {
        echo $((($1 + $2 - 1)/$2))
}

# Compute a value for a FAT32 filesystem's reserved sector count which results
# in the start of the data area aligning with an eraseblock boundary.
#
# A FAT32 filesystem is structured as follows:
#
#     [ reserved sectors ][ FAT #1 ][ additional FATs ][ data area ]
#
# The first sector (part of the reserved range) is typically a boot sector,
# whereas the second sector is a filesystem information block for FAT32.
# Additional reserved sectors can be required by the boot sector code;
# Windows usually reserves at least 12 sectors at the beginning of the
# filesystem for this.  Typically, two copies of the FAT are stored
# back-to-back, though a different number is at least theoretically possible.
#
# As with other filesystems, ensuring the start of the data area is aligned to
# an eraseblock boundary is important for performance; unfortunately, mkdosfs
# is not able to do this for us (the best it can do is align structures to
# clusters, which are considerably smaller than flash eraseblocks are on recent
# media).  Good flash vendors do this with their factory-formatted media (look
# at any factory-fresh SanDisk SD card with dosfsck -v, for example).
#
# Aligning the start of the data area essentially means ensuring that the FATs
# plus the reserved sectors extend over the whole of one or more eraseblocks.
# We can have an arbitrary number of reserved sectors, so the obvious strategy
# is to determine the size of the FATs and then use reserved sectors to pad
# to the nearest eraseblock boundary.  However, FAT size is determined by the
# size of the data area:
#
#     FAT32 size = 4 bytes * (number of data clusters + 2)
#
# (clusters are groups of 2^N sectors which form the basic allocation unit of
# the filesystem).
#
# How, then, to compute the needed number or reserved sectors?  We first note
# that, according to the above formula, each data cluster requires four bytes
# in FAT space.  Treating the minimum of 12 reserved sectors and the 8 bytes at
# the beginning of each FAT as overhead, we come to the following way of
# dividing up our volume:
#
#     [12 reserved sectors][8 bytes FAT#1][8 bytes FAT#2][chunk][chunk][...]
#
# where each "chunk" consists of one cluster plus the space needed to track it
# in the FATs:
# 
#     [cluster][4 bytes in FAT#1][4 bytes in FAT#2]
#
# Computing the number of these chunks that fit in our volume will give us the
# largest possible data area, and therefore the largest possible FAT, that can
# be used on this filesystem.  We then find the smallest number of eraseblocks
# that will fit two copies of the maximal FAT and the minimum number of reserved
# sectors, and offset the start of the data area by that amount.  This gives
# us the final data area size, from which we can compute the actual size of the
# FATs (guaranteed to be no larger than the maximal FAT) and the appropriate
# number of reserved sectors to take up the remainder of the eraseblocks
# set aside for reserved sectors and FATs.
#
# The actual computations below follow the process described above, though
# they're complicated by the need in many places to round to the nearest whole
# unit when dividing.

align_reserved_sectors() {
	sdcard_sectors="$1"
	ERASEBLOCK_SIZE="$2"

	SECTORS_PER_ERASEBLOCK=$(($ERASEBLOCK_SIZE/512))
	CLUSTERS_PER_ERASEBLOCK=$(($ERASEBLOCK_SIZE/$CLUSTER_SIZE))

	# Once aligned, the data area will consist of some number of clusters
	# starting at a multiple of the eraseblock size (which is divisible by
	# the cluster size).  If the filesystem size isn't an integer multiple
	# of the cluster size, the leftover area at the end is unusable and
	# should not factor into our calculations.  Therefore, we represent
	# the filesystem size in whole clusters throughout, ignoring leftover
	# sectors if they exist.
	sdcard_clusters=$(($sdcard_sectors/$SECTORS_PER_CLUSTER))

	# Calculate the maximal FAT size in bytes (rounded up to the nearest
	# whole chunk), then round the size up to the nearest whole sector
	fat_size_bytes=$((4*$(div_round_up $((($sdcard_clusters*$SECTORS_PER_CLUSTER - $MIN_RESERVED_SECTORS)*512 - 8*$NUM_FATS)) $(($CLUSTER_SIZE + $NUM_FATS*4))) + 8))
	fat_sectors=$(div_round_up $fat_size_bytes 512)

	# Compute the number of eraseblocks needed to hold the two FATs plus
	# required reserve sectors (12)
	fat_data_offset_ebs=$(div_round_up $(($NUM_FATS*$fat_sectors + $MIN_RESERVED_SECTORS)) $SECTORS_PER_ERASEBLOCK)

	# Calculate the actual FAT size assuming that we set aside whole
	# eraseblocks to hold reserved sectors and FATs
	fat_size_bytes=$((($sdcard_clusters - $fat_data_offset_ebs*$CLUSTERS_PER_ERASEBLOCK)*4 + 8))
	fat_sectors=$(div_round_up $fat_size_bytes 512)

	# Compute the final number of reserved sectors needed to pad out the
	# FATs to eraseblock size
	reserved_sectors=$(($fat_data_offset_ebs*$SECTORS_PER_ERASEBLOCK - $NUM_FATS * $fat_sectors))

	if [ x"$3" = x"test" ]; then
		# For use by the test suite
		echo "$reserved_sectors $fat_data_offset_ebs $fat_size_bytes $fat_sectors"
	else
		echo $reserved_sectors
	fi
}
