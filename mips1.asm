.data
bad_args:	.asciiz	"Too few arguemnts, exiting the application..."
.align 3
buf:		.space	51840			# == 3 B/pixel * 1920 pixel/row * 9 row
pad:		.space	3
max_R:		.space	1
max_G:		.space	1
max_B:		.space	1
.text
#main:
	beq	$a0,	3,	args_ok
	li	$v0,	4
	la	$a0,	bad_args
	syscall
	b	quit

args_ok:
	lw	$s0,	($a1)			# address under which infile name is strored
	lw	$s1,	4($a1)			# address under which outfile name is stored
	lw	$s2,	8($a1)			# address under which the filter box size is stored as a string

#read_infile_header:
	li	$v0,	13			# open file
	move	$a0,	$s0
	li	$a1,	0			# read-only
	syscall
	move	$s0,	$v0			# move the file descriptor to s0, since we don't need its name any longer
	bltz	$s0,	quit			# error
	
	li	$v0,	14			# read its header
	move	$a0,	$s0
	la	$a1,	buf+2			# so that we read from buf addresses aligend to 4 bytes 
	li	$a2,	54
	syscall
	bne	$v0,	54,	close_in	# error
	
	lw	$s3,	buf+20			# width
	lw	$s4,	buf+24			# height
	
	bgt	$s3,	1920,	close_in	# max width error
	lh	$t0,	buf+2
	bne	$t0,	0x4D42,	close_in	# signature error
	lw	$t0,	buf+8
	bnez	$t0,	quit			# must-be-zero error
	lh	$t0,	buf+16
	bne	$t0,	40,	close_in	# bitmapinfoheader size error
	
	lw	$t0,	buf+12			# offset to pixel array
	move	$a0,	$s0	
	la	$a1,	buf+56
	sub	$a2,	$t0,	54		# a0 already contains file descriptor and a1 the address of the image buffer
	li	$v0,	14			# read till the beginning of the pixel array	
	syscall
	
	li	$v0,	13			# open and create the outfile
	move	$a0,	$s1
	li	$a1,	9
	syscall
	move	$s1,	$v0
	bltz	$s1,	quit			# opening file for writing error
	
	li	$v0,	15			# write header and bitmapinfoheader
	move	$a0,	$s1
	la	$a1,	buf+2
	move	$a2,	$t0
	syscall
	bne	$v0,	$t0,	quit		# write to file error
	
	mul	$t0,	$s3,	3		# calculate padding
	li	$t1,	4
	div	$t0,	$t1
	mfhi	$s5				# remainder
	beqz	$s5,	atoi_prep		
	sub	$s5,	$t1,	$s5
	
atoi_prep:	
	li	$t0,	0			# the current char
	li	$t1,	0			# the calculated box size
atoi:
	lb	$t0,	($s2)			# load a char
	beq	$t0,	0,	atoi_end	# end if null
	blt	$t0,	48,	quit		# not a digit
	bgt	$t0,	57,	quit		# not a digit
	mulu	$t1,	$t1,	10		# dec shift calculated value
	subiu	$t0,	$t0,	48		# char-48==digit
	addu	$t1,	$t1,	$t0		# value+=digit 
	addiu	$s2,	$s2,	1		# on to the next byte (char)
	b	atoi
atoi_end:
	move	$s2,	$t1			# now s2 contains the filter box size as an integer
	blez	$s2,	quit			# no need to go through the filtering algorithm if the box size is <= 0
	mul	$t0,	$s3,	3
	li	$t1,	51840
	sub	$t1,	$t1,	$t0
	mul	$t0,	$t0,	2
	div	$t1,	$t1,	$t0
	bgt	$s2,	$t1,	quit		# the max box size for a given image equals (buffer_size-3*width)/(6*width)

# s0 - infile descr, s1 - outfile descr, s2 - box size,
# s3 - width, s4 - height, s5 - padding in Bytes	

	li	$t0,	0
	move	$a0,	$s0
read_initial_rows:
# read the first box+1 rows of the bmp file into the buffer
	li	$v0,	14				#read row data
	mul	$t1,	$t0,	$s3
	mul	$t1,	$t1,	3
	la	$a1,	buf($t1)
	move	$a2,	$s3
	syscall
	#### if end of file ( $v0 == 0 ) was read then this means there are less than box+1 rows and wee need to end loop
	beqz	$v0,	filter_prep
	bne	$v0,	$s3,	quit			# error
	
	li	$v0,	14				# read padding
	la	$a1,	pad
	move	$a2,	$s5
	syscall
	bne	$v0,	$s5,	quit			# error
	
	addiu	$t0,	$t0,	1
	ble	$t0,	$s2,	read_initial_rows
	
filter_prep:	
# s0 - infile descr, s1 - outfile descr, s2 - box size,
# s3 - width, s4 - height, s5 - padding in Bytes

# t0 - X column number of the filtered pixel, t1 - Y its row number
# t2 - minX checked column, t3 - maxX checked column for filtered pixel
# t4 - minY checked row, t5 - maxY checked row
# t6 - X column of the currently checked pixel t7 - Y its row
	li	$t0,	0
	li	$t1,	0
	li	$t2,	0
	li	$t3,	0
	li	$t4,	0
	li	$t5,	0
	li	$t6,	0
	li	$t7,	0
	mul	$s6,	$s2,	2	
	addiu	$s6,	$s6,	1	# 2*box+1, we'll need that later on

min_Y_c:
	sub	$t4,	$t1,	$s2
	bgez	$t4,	max_Y_c
	li	$t4,	0
max_Y_c:
	add	$t5,	$t1,	$s2
	blt	$t5,	$s4,	min_X_c
	subiu	$t5,	$s4,	1
min_X_c:
	sub	$t2,	$t0,	$s2
	bgez	$t2,	max_X_c
	li	$t2,	0
max_X_c:
	add	$t3,	$t0,	$s2
	blt	$t3,	$s3,	init_RGB
	subiu	$t3,	$s3,	1
init_RGB:
	#save filtered pixel's RGB 3 bytes into a register; its cooradinates are: t0,t1, so its address is: buf+3*( w*(Y%(2box+1)) +X)
#	div	$t1,	$s6
#	mfhi	$t8
#	mul	$t8,	$t8,	$s3
#	add	$t8,	$t8,	$t0
#	mul	$t8,	$t8,	3
#	
#	#save 3 bytes following buf($t8) into some other thingy there is no guarantee of alignment so youd better read byte by byte
#	lb	$t6,	buf($t8)
#	lb	$t7,	1+buf($t8)
#	lb	$t9,	2+buf($t8)
	sb	$zero,	pad
	sb	$zero,	pad+1
	sb	$zero,	pad+2	
init_Y:
	move	$t7,	$t4
init_X:
	move	$t6,	$t2
locate_pixel_in_box:
	# now check a single pixel of coordinates (t6,t7) in the picture - locate its address in the buffer
	div	$t7,	$s6
	mfhi	$t8
	mul	$t8,	$t8,	$s3
	add	$t8,	$t8,	$t6
	mul	$t8,	$t8,	3
	#save 3 bytes following buf($t8) into some other thingy there is no guarantee of alignment so youd better read byte by byte
check_R:
	lb	$t9,	buf($t8)
	lb	$s7,	max_R
	ble	$t9,	$s7,	check_G
	sb	$t9,	max_R
check_G:
	lb	$t9,	1+buf($t8)
	lb	$s7,	max_G
	ble	$t9,	$s7,	check_B
	sb	$t9,	max_G
check_B:	
	lb	$t9,	2+buf($t8)
	lb	$s7,	max_B
	ble	$t9,	$s7,	check_next_pixel
	sb	$t9,	max_B
check_next_pixel:
	addiu	$t6,	$t6,	1			
	addiu	$t8,	$t8,	3			# move on to the next pixel in the row, add 3 to the offset, no need to calculate the addres if we're not changing the line
	ble	$t6,	$t3,	check_R
	addiu	$t7,	$t7,	1
	ble	$t7,	$t5,	init_X
save_pixel:
	#maxRGB is now found, the only job left to do is now to save the pixel of coordinates (t0,t1) to output
	li	$v0,	15
	move	$a0,	$s1
	la	$a1,	pad
	li	$a2,	3
	syscall
	bltz	$v0,	quit				# error
filter_next_pixel:	#before branching we need to load another row into the address: buf + 3 * width * [(loop+box+1) % (2*box+1)] and then read padding
	addiu	$t0,	$t0,	1	# X_filtering ++ ; if < width then calculate maxXc and minXc, zero out max colors, Y's stay the same
	blt	$t0,	$s3,	min_X_c
	
	addiu	$t1,	$t1,	1	# otherwise we filtered the whole line and now we need to increment filtered pixel's Y and set its X to 0
	li	$v0,	15		# and write the offset to the outfile
	move	$a0,	$s1
	la	$a1,	pad
	move	$a2,	$s5
	syscall
	bltz	$v0,	quit				# error 
	beq	$t1,	$s4,	quit	# end the program if its Y is now maximal (==height)
	
	li	$t0,	0
	sub	$t8,	$s4,	$s2			# height-box
	bge	$t1,	$t8,	min_Y_c			# don't load any next lines into the buf for iterations >= height-box
	
	add	$t8,	$t1,	$s2
	div	$t8,	$s6				# s6 already contains 2*box+1
	mfhi	$t8					# [(loop+box+1) % (2*box+1)]
	mul	$t8,	$t8,	$s3			# * width
	mul	$t8,	$t8,	3			# * 3
	
	li	$v0,	14				# read row data
	la	$a1,	buf($t8)
	mul	$a2,	$s2,	3
	syscall
	bne	$v0,	$s3,	quit			# error
	
	li	$v0,	14				# read padding
	la	$a1,	pad
	move	$a2,	$s5
	syscall
	bne	$v0,	$s5,	quit			# error
	
	b	min_Y_c					# on to the next line
	
quit:
#close_out:
	li	$v0,	16			# close outfile
	move	$a0,	$s1
	syscall
close_in:	
	li	$v0,	16			# close infile
	move	$a0,	$s0
	syscall
#exit:	
	li	$v0,	10			# exit
	syscall
