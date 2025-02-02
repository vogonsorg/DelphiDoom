//------------------------------------------------------------------------------
//
//  DelphiDoom is a source port of the game Doom and it is
//  based on original Linux Doom as published by "id Software"
//  Copyright (C) 2004-2022 by Jim Valavanis
//
//  This program is free software; you can redistribute it and/or
//  modify it under the terms of the GNU General Public License
//  as published by the Free Software Foundation; either version 2
//  of the License, or (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program; if not, write to the Free Software
//  Foundation, inc., 59 Temple Place - Suite 330, Boston, MA
//  02111-1307, USA.
//
//------------------------------------------------------------------------------
//  E-Mail: jimmyvalavanis@yahoo.gr
//  Site  : https://sourceforge.net/projects/delphidoom/
//------------------------------------------------------------------------------

{$I Doom32.inc}

unit jpg_Quant2;

{ This file contains 2-pass color quantization (color mapping) routines.
  These routines provide selection of a custom color map for an image,
  followed by mapping of the image to that color map, with optional
  Floyd-Steinberg dithering.
  It is also possible to use just the second pass to map to an arbitrary
  externally-given color map.

  Note: ordered dithering is not supported, since there isn't any fast
  way to compute intercolor distances; it's unclear that ordered dither's
  fundamental assumptions even hold with an irregularly spaced color map. }

{ Original: jquant2.c; Copyright (C) 1991-1996, Thomas G. Lane. }

interface

{$I jconfig.inc}

uses
  jpg_morecfg,
  jpg_error,
  jpg_utils,
  jpg_lib;

{ Module initialization routine for 2-pass color quantization. }

{GLOBAL}

//==============================================================================
//
// jinit_2pass_quantizer 
//
//==============================================================================
procedure jinit_2pass_quantizer (cinfo: j_decompress_ptr);

implementation

uses
  jpg_defErr;

{ This module implements the well-known Heckbert paradigm for color
  quantization.  Most of the ideas used here can be traced back to
  Heckbert's seminal paper
    Heckbert, Paul.  "Color Image Quantization for Frame Buffer Display",
    Proc. SIGGRAPH '82, Computer Graphics v.16 #3 (July 1982), pp 297-304.

  In the first pass over the image, we accumulate a histogram showing the
  usage count of each possible color.  To keep the histogram to a reasonable
  size, we reduce the precision of the input; typical practice is to retain
  5 or 6 bits per color, so that 8 or 4 different input values are counted
  in the same histogram cell.

  Next, the color-selection step begins with a box representing the whole
  color space, and repeatedly splits the "largest" remaining box until we
  have as many boxes as desired colors.  Then the mean color in each
  remaining box becomes one of the possible output colors.

  The second pass over the image maps each input pixel to the closest output
  color (optionally after applying a Floyd-Steinberg dithering correction).
  This mapping is logically trivial, but making it go fast enough requires
  considerable care.

  Heckbert-style quantizers vary a good deal in their policies for choosing
  the "largest" box and deciding where to cut it.  The particular policies
  used here have proved out well in experimental comparisons, but better ones
  may yet be found.

  In earlier versions of the IJG code, this module quantized in YCbCr color
  space, processing the raw upsampled data without a color conversion step.
  This allowed the color conversion math to be done only once per colormap
  entry, not once per pixel.  However, that optimization precluded other
  useful optimizations (such as merging color conversion with upsampling)
  and it also interfered with desired capabilities such as quantizing to an
  externally-supplied colormap.  We have therefore abandoned that approach.
  The present code works in the post-conversion color space, typically RGB.

  To improve the visual quality of the results, we actually work in scaled
  RGB space, giving G distances more weight than R, and R in turn more than
  B.  To do everything in integer math, we must use integer scale factors.
  The 2/3/1 scale factors used here correspond loosely to the relative
  weights of the colors in the NTSC grayscale equation.
  If you want to use this code to quantize a non-RGB color space, you'll
  probably need to change these scale factors. }

const
  R_SCALE = 2;          { scale R distances by this much }
  G_SCALE = 3;          { scale G distances by this much }
  B_SCALE = 1;          { and B by this much }

{ Relabel R/G/B as components 0/1/2, respecting the RGB ordering defined
  in jmorecfg.h.  As the code stands, it will do the right thing for R,G,B
  and B,G,R orders.  If you define some other weird order in jmorecfg.h,
  you'll get compile errors until you extend this logic.  In that case
  you'll probably want to tweak the histogram sizes too. }

{$ifdef RGB_RED_IS_0}
const
  C0_SCALE = R_SCALE;
  C1_SCALE = G_SCALE;
  C2_SCALE = B_SCALE;
{$else}
const
  C0_SCALE = B_SCALE;
  C1_SCALE = G_SCALE;
  C2_SCALE = R_SCALE;
{$endif}

{ First we have the histogram data structure and routines for creating it.

  The number of bits of precision can be adjusted by changing these symbols.
  We recommend keeping 6 bits for G and 5 each for R and B.
  If you have plenty of memory and cycles, 6 bits all around gives marginally
  better results; if you are short of memory, 5 bits all around will save
  some space but degrade the results.
  To maintain a fully accurate histogram, we'd need to allocate a "long"
  (preferably unsigned long) for each cell.  In practice this is overkill;
  we can get by with 16 bits per cell.  Few of the cell counts will overflow,
  and clamping those that do overflow to the maximum value will give close-
  enough results.  This reduces the recommended histogram size from 256Kb
  to 128Kb, which is a useful savings on PC-class machines.
  (In the second pass the histogram space is re-used for pixel mapping data;
  in that capacity, each cell must be able to store zero to the number of
  desired colors.  16 bits/cell is plenty for that too.)
  Since the JPEG code is intended to run in small memory model on 80x86
  machines, we can't just allocate the histogram in one chunk.  Instead
  of a true 3-D array, we use a row of pointers to 2-D arrays.  Each
  pointer corresponds to a C0 value (typically 2^5 = 32 pointers) and
  each 2-D array has 2^6*2^5 = 2048 or 2^6*2^6 = 4096 entries.  Note that
  on 80x86 machines, the pointer row is in near memory but the actual
  arrays are in far memory (same arrangement as we use for image arrays). }

const
  MAXNUMCOLORS = (MAXJSAMPLE+1);        { maximum size of colormap }

{ These will do the right thing for either R,G,B or B,G,R color order,
  but you may not like the results for other color orders. }

const
  HIST_C0_BITS = 5;             { bits of precision in R/B histogram }
  HIST_C1_BITS = 6;             { bits of precision in G histogram }
  HIST_C2_BITS = 5;             { bits of precision in B/R histogram }

{ Number of elements along histogram axes. }
const
  HIST_C0_ELEMS = (1 shl HIST_C0_BITS);
  HIST_C1_ELEMS = (1 shl HIST_C1_BITS);
  HIST_C2_ELEMS = (1 shl HIST_C2_BITS);

{ These are the amounts to shift an input value to get a histogram index. }
const
  C0_SHIFT = (BITS_IN_JSAMPLE-HIST_C0_BITS);
  C1_SHIFT = (BITS_IN_JSAMPLE-HIST_C1_BITS);
  C2_SHIFT = (BITS_IN_JSAMPLE-HIST_C2_BITS);

type                            { Nomssi }
  RGBptr = ^RGBtype;
  RGBtype = packed record
    r,g,b: JSAMPLE;
  end;
type
  histcell = UINT16;            { histogram cell; prefer an unsigned type }

type
  histptr = ^histcell {FAR};       { for pointers to histogram cells }

type
  hist1d = array[0..HIST_C2_ELEMS-1] of histcell; { typedefs for the array }
  {hist1d_ptr = ^hist1d;}
  hist1d_field = array[0..HIST_C1_ELEMS-1] of hist1d;
                                  { type for the 2nd-level pointers }
  hist2d = ^hist1d_field;
  hist2d_field = array[0..HIST_C0_ELEMS-1] of hist2d;
  hist3d = ^hist2d_field;    { type for top-level pointer }

{ Declarations for Floyd-Steinberg dithering.

  Errors are accumulated into the array fserrors[], at a resolution of
  1/16th of a pixel count.  The error at a given pixel is propagated
  to its not-yet-processed neighbors using the standard F-S fractions,
     ...  (here)  7/16
     3/16  5/16  1/16
  We work left-to-right on even rows, right-to-left on odd rows.

  We can get away with a single array (holding one row's worth of errors)
  by using it to store the current row's errors at pixel columns not yet
  processed, but the next row's errors at columns already processed.  We
  need only a few extra variables to hold the errors immediately around the
  current column.  (If we are lucky, those variables are in registers, but
  even if not, they're probably cheaper to access than array elements are.)

  The fserrors[] array has (#columns + 2) entries; the extra entry at
  each end saves us from special-casing the first and last pixels.
  Each entry is three values long, one value for each color component.

  Note: on a wide image, we might not have enough room in a PC's near data
  segment to hold the error array; so it is allocated with alloc_large. }

{$ifdef BITS_IN_JSAMPLE_IS_8}
type
  FSERROR = INT16;              { 16 bits should be enough }
  LOCFSERROR = int;             { use 'int' for calculation temps }
{$else}
type
  FSERROR = INT32;              { may need more than 16 bits }
  LOCFSERROR = INT32;           { be sure calculation temps are big enough }
{$endif}
type                            { Nomssi }
  RGB_FSERROR_PTR = ^RGB_FSERROR;
  RGB_FSERROR = packed record
    r,g,b: FSERROR;
  end;
  LOCRGB_FSERROR = packed record
    r,g,b: LOCFSERROR;
  end;

type
  FSERROR_PTR = ^FSERROR;
  jFSError = 0..(MaxInt div SizeOf(RGB_FSERROR))-1;
  FS_ERROR_FIELD = array[jFSError] of RGB_FSERROR;
  FS_ERROR_FIELD_PTR = ^FS_ERROR_FIELD;{far}
                                { pointer to error array (in FAR storage!) }

type
  error_limit_array = array[-MAXJSAMPLE..MAXJSAMPLE] of int;
  { table for clamping the applied error }
  error_limit_ptr = ^error_limit_array;

{ Private subobject }
type
  my_cquantize_ptr = ^my_cquantizer;
  my_cquantizer = record
    pub: jpeg_color_quantizer; { public fields }

    { Space for the eventually created colormap is stashed here }
    sv_colormap: JSAMPARRAY;  { colormap allocated at init time }
    desired: int;              { desired # of colors = size of colormap }

    { Variables for accumulating image statistics }
    histogram: hist3d;         { pointer to the histogram }

    needs_zeroed: boolean;     { TRUE if next pass must zero histogram }

    { Variables for Floyd-Steinberg dithering }
    fserrors: FS_ERROR_FIELD_PTR;        { accumulated errors }
    on_odd_row: boolean;       { flag to remember which row we are on }
    error_limiter: error_limit_ptr; { table for clamping the applied error }
  end;

{ Prescan some rows of pixels.
  In this module the prescan simply updates the histogram, which has been
  initialized to zeroes by start_pass.
  An output_buf parameter is required by the method signature, but no data
  is actually output (in fact the buffer controller is probably passing a
  nil pointer). }

{METHODDEF}

//==============================================================================
//
// prescan_quantize
//
//==============================================================================
procedure prescan_quantize(cinfo: j_decompress_ptr; input_buf: JSAMPARRAY;
  output_buf: JSAMPARRAY; num_rows: int); far;
var
  cquantize: my_cquantize_ptr;
  {register} ptr: RGBptr;
  {register} histp: histptr;
  {register} histogram: hist3d;
  row: int;
  col: JDIMENSION;
  width: JDIMENSION;
begin
  cquantize := my_cquantize_ptr(cinfo^.cquantize);
  histogram := cquantize^.histogram;
  width := cinfo^.output_width;

  for row := 0 to pred(num_rows) do
  begin
    ptr := RGBptr(input_buf^[row]);
    for col := pred(width) downto 0 do
    begin
      { get pixel value and index into the histogram }
      histp := @(histogram^[GETJSAMPLE(ptr^.r) shr C0_SHIFT]^
                           [GETJSAMPLE(ptr^.g) shr C1_SHIFT]
         [GETJSAMPLE(ptr^.b) shr C2_SHIFT]);
      { increment, check for overflow and undo increment if so. }
      inc(histp^);
      if (histp^ <= 0) then
  dec(histp^);
      inc(ptr);
    end;
  end;
end;

{ Next we have the really interesting routines: selection of a colormap
  given the completed histogram.
  These routines work with a list of "boxes", each representing a rectangular
  subset of the input color space (to histogram precision). }

type
  box = record
  { The bounds of the box (inclusive); expressed as histogram indexes }
    c0min, c0max: int;
    c1min, c1max: int;
    c2min, c2max: int;
    { The volume (actually 2-norm) of the box }
    volume: INT32;
    { The number of nonzero histogram cells within this box }
    colorcount: long;
  end;

type
  jBoxList = 0..(MaxInt div SizeOf(box))-1;
  box_field = array[jBoxlist] of box;
  boxlistptr = ^box_field;
  boxptr = ^box;

{LOCAL}

//==============================================================================
//
// find_biggest_color_pop 
//
//==============================================================================
function find_biggest_color_pop (boxlist: boxlistptr; numboxes: int): boxptr;
{ Find the splittable box with the largest color population }
{ Returns nil if no splittable boxes remain }
var
  boxp: boxptr ; {register}
  i: int;        {register}
  maxc: long;    {register}
  which: boxptr;
begin
  which := nil;
  boxp := @(boxlist^[0]);
  maxc := 0;
  for i := 0 to pred(numboxes) do
  begin
    if (boxp^.colorcount > maxc) and (boxp^.volume > 0) then
    begin
      which := boxp;
      maxc := boxp^.colorcount;
    end;
    inc(boxp);
  end;
  find_biggest_color_pop := which;
end;

{LOCAL}

//==============================================================================
//
// find_biggest_volume 
//
//==============================================================================
function find_biggest_volume (boxlist: boxlistptr; numboxes: int): boxptr;
{ Find the splittable box with the largest (scaled) volume }
{ Returns NULL if no splittable boxes remain }
var
  {register} boxp: boxptr;
  {register} i: int;
  {register} maxv: INT32;
  which: boxptr;
begin
  maxv := 0;
  which := nil;
  boxp := @(boxlist^[0]);
  for i := 0 to pred(numboxes) do
  begin
    if (boxp^.volume > maxv) then
    begin
      which := boxp;
      maxv := boxp^.volume;
    end;
    inc(boxp);
  end;
  find_biggest_volume := which;
end;

{LOCAL}

//==============================================================================
//
// update_box 
//
//==============================================================================
procedure update_box (cinfo: j_decompress_ptr; var boxp: box);
label
  have_c0min, have_c0max,
  have_c1min, have_c1max,
  have_c2min, have_c2max;
{ Shrink the min/max bounds of a box to enclose only nonzero elements, }
{ and recompute its volume and population }
var
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  histp: histptr;
  c0,c1,c2: int;
  c0min,c0max,c1min,c1max,c2min,c2max: int;
  dist0,dist1,dist2: INT32;
  ccount: long;
begin
  cquantize := my_cquantize_ptr(cinfo^.cquantize);
  histogram := cquantize^.histogram;

  c0min := boxp.c0min;  c0max := boxp.c0max;
  c1min := boxp.c1min;  c1max := boxp.c1max;
  c2min := boxp.c2min;  c2max := boxp.c2max;

  if (c0max > c0min) then
    for c0 := c0min to c0max do
      for c1 := c1min to c1max do
      begin
  histp := @(histogram^[c0]^[c1][c2min]);
  for c2 := c2min to c2max do
        begin
    if (histp^ <> 0) then
          begin
            c0min := c0;
      boxp.c0min := c0min;
      goto have_c0min;
    end;
          inc(histp);
        end;
      end;
 have_c0min:
  if (c0max > c0min) then
    for c0 := c0max downto c0min do
      for c1 := c1min to c1max do
      begin
  histp := @(histogram^[c0]^[c1][c2min]);
  for c2 := c2min to c2max do
        begin
    if ( histp^ <> 0) then
          begin
            c0max := c0;
      boxp.c0max := c0;
      goto have_c0max;
    end;
          inc(histp);
        end;
      end;
 have_c0max:
  if (c1max > c1min) then
    for c1 := c1min to c1max do
      for c0 := c0min to c0max do
      begin
  histp := @(histogram^[c0]^[c1][c2min]);
  for c2 := c2min to c2max do
        begin
    if (histp^ <> 0) then
          begin
            c1min := c1;
      boxp.c1min := c1;
      goto have_c1min;
    end;
          inc(histp);
        end;
      end;
 have_c1min:
  if (c1max > c1min) then
    for c1 := c1max downto c1min do
      for c0 := c0min to c0max do
      begin
        histp := @(histogram^[c0]^[c1][c2min]);
        for c2 := c2min to c2max do
        begin
          if (histp^ <> 0) then
          begin
            c1max := c1;
            boxp.c1max := c1;
            goto have_c1max;
          end;
          inc(histp);
        end;
      end;
 have_c1max:
  if (c2max > c2min) then
    for c2 := c2min to c2max do
      for c0 := c0min to c0max do
      begin
        histp := @(histogram^[c0]^[c1min][c2]);
        for c1 := c1min to c1max do
        begin
          if (histp^ <> 0) then
          begin
            c2min := c2;
            boxp.c2min := c2min;
            goto have_c2min;
          end;
          inc(histp, HIST_C2_ELEMS);
        end;
      end;
 have_c2min:
  if (c2max > c2min) then
    for c2 := c2max downto c2min do
      for c0 := c0min to c0max do
      begin
        histp := @(histogram^[c0]^[c1min][c2]);
        for c1 := c1min to c1max do
        begin
          if (histp^ <> 0) then
          begin
            c2max := c2;
            boxp.c2max := c2max;
            goto have_c2max;
          end;
          inc(histp, HIST_C2_ELEMS);
        end;
      end;
 have_c2max:

  { Update box volume.
    We use 2-norm rather than real volume here; this biases the method
    against making long narrow boxes, and it has the side benefit that
    a box is splittable iff norm > 0.
    Since the differences are expressed in histogram-cell units,
    we have to shift back to JSAMPLE units to get consistent distances;
    after which, we scale according to the selected distance scale factors.}

  dist0 := ((c0max - c0min) shl C0_SHIFT) * C0_SCALE;
  dist1 := ((c1max - c1min) shl C1_SHIFT) * C1_SCALE;
  dist2 := ((c2max - c2min) shl C2_SHIFT) * C2_SCALE;
  boxp.volume := dist0*dist0 + dist1*dist1 + dist2*dist2;

  { Now scan remaining volume of box and compute population }
  ccount := 0;
  for c0 := c0min to c0max do
    for c1 := c1min to c1max do
    begin
      histp := @(histogram^[c0]^[c1][c2min]);
      for c2 := c2min to c2max do
      begin
        if (histp^ <> 0) then
          inc(ccount);
        inc(histp);
      end;
    end;
  boxp.colorcount := ccount;
end;

{LOCAL}

//==============================================================================
//
// median_cut
//
//==============================================================================
function median_cut(cinfo: j_decompress_ptr; boxlist: boxlistptr; numboxes: int;
  desired_colors: int): int;
{ Repeatedly select and split the largest box until we have enough boxes }
var
  n,lb: int;
  c0,c1,c2,cmax: int;
  {register} b1,b2: boxptr;
begin
  while (numboxes < desired_colors) do
  begin
    { Select box to split.
      Current algorithm: by population for first half, then by volume. }

    if (numboxes*2 <= desired_colors) then
      b1 := find_biggest_color_pop(boxlist, numboxes)
    else
      b1 := find_biggest_volume(boxlist, numboxes);

    if (b1 = nil) then          { no splittable boxes left! }
      break;
    b2 := @(boxlist^[numboxes]);  { where new box will go }
    { Copy the color bounds to the new box. }
    b2^.c0max := b1^.c0max; b2^.c1max := b1^.c1max; b2^.c2max := b1^.c2max;
    b2^.c0min := b1^.c0min; b2^.c1min := b1^.c1min; b2^.c2min := b1^.c2min;
    { Choose which axis to split the box on.
      Current algorithm: longest scaled axis.
      See notes in update_box about scaling distances. }

    c0 := ((b1^.c0max - b1^.c0min) shl C0_SHIFT) * C0_SCALE;
    c1 := ((b1^.c1max - b1^.c1min) shl C1_SHIFT) * C1_SCALE;
    c2 := ((b1^.c2max - b1^.c2min) shl C2_SHIFT) * C2_SCALE;
    { We want to break any ties in favor of green, then red, blue last.
      This code does the right thing for R,G,B or B,G,R color orders only. }

{$ifdef RGB_RED_IS_0}
    cmax := c1; n := 1;
    if (c0 > cmax) then
    begin
      cmax := c0;
      n := 0;
    end;
    if (c2 > cmax) then
      n := 2;
{$else}
    cmax := c1;
    n := 1;
    if (c2 > cmax) then
    begin
      cmax := c2;
      n := 2;
    end;
    if (c0 > cmax) then
      n := 0;
{$endif}
    { Choose split point along selected axis, and update box bounds.
      Current algorithm: split at halfway point.
      (Since the box has been shrunk to minimum volume,
      any split will produce two nonempty subboxes.)
      Note that lb value is max for lower box, so must be < old max. }

    case n of
    0:begin
        lb := (b1^.c0max + b1^.c0min) div 2;
        b1^.c0max := lb;
        b2^.c0min := lb+1;
      end;
    1:begin
        lb := (b1^.c1max + b1^.c1min) div 2;
        b1^.c1max := lb;
        b2^.c1min := lb+1;
      end;
    2:begin
        lb := (b1^.c2max + b1^.c2min) div 2;
        b1^.c2max := lb;
        b2^.c2min := lb+1;
      end;
    end;
    { Update stats for boxes }
    update_box(cinfo, b1^);
    update_box(cinfo, b2^);
    inc(numboxes);
  end;
  median_cut := numboxes;
end;

{LOCAL}

//==============================================================================
//
// compute_color
//
//==============================================================================
procedure compute_color(cinfo: j_decompress_ptr; const boxp: box; icolor: int);
{ Compute representative color for a box, put it in colormap[icolor] }
var
  { Current algorithm: mean weighted by pixels (not colors) }
  { Note it is important to get the rounding correct! }
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  histp: histptr;
  c0,c1,c2: int;
  c0min,c0max,c1min,c1max,c2min,c2max: int;
  count: long;
  total: long;
  c0total: long;
  c1total: long;
  c2total: long;
begin
  cquantize := my_cquantize_ptr(cinfo^.cquantize);
  histogram := cquantize^.histogram;
  total := 0;
  c0total := 0;
  c1total := 0;
  c2total := 0;

  c0min := boxp.c0min;  c0max := boxp.c0max;
  c1min := boxp.c1min;  c1max := boxp.c1max;
  c2min := boxp.c2min;  c2max := boxp.c2max;

  for c0 := c0min to c0max do
    for c1 := c1min to c1max do
    begin
      histp := @(histogram^[c0]^[c1][c2min]);
      for c2 := c2min to c2max do
      begin
  count := histp^;
        inc(histp);
  if (count <> 0) then
        begin
    inc(total, count);
    inc(c0total, ((c0 shl C0_SHIFT) + ((1 shl C0_SHIFT) shr 1)) * count);
    inc(c1total, ((c1 shl C1_SHIFT) + ((1 shl C1_SHIFT) shr 1)) * count);
    inc(c2total, ((c2 shl C2_SHIFT) + ((1 shl C2_SHIFT) shr 1)) * count);
  end;
      end;
    end;

  cinfo^.colormap^[0]^[icolor] := JSAMPLE ((c0total + (total shr 1)) div total);
  cinfo^.colormap^[1]^[icolor] := JSAMPLE ((c1total + (total shr 1)) div total);
  cinfo^.colormap^[2]^[icolor] := JSAMPLE ((c2total + (total shr 1)) div total);
end;

{LOCAL}

//==============================================================================
//
// select_colors 
//
//==============================================================================
procedure select_colors (cinfo: j_decompress_ptr; desired_colors: int);
{ Master routine for color selection }
var
  boxlist: boxlistptr;
  numboxes: int;
  i: int;
begin
  { Allocate workspace for box list }
  boxlist := boxlistptr(cinfo^.mem^.alloc_small(
    j_common_ptr(cinfo), JPOOL_IMAGE, desired_colors * SizeOf(box)));
  { Initialize one box containing whole space }
  numboxes := 1;
  boxlist^[0].c0min := 0;
  boxlist^[0].c0max := MAXJSAMPLE shr C0_SHIFT;
  boxlist^[0].c1min := 0;
  boxlist^[0].c1max := MAXJSAMPLE shr C1_SHIFT;
  boxlist^[0].c2min := 0;
  boxlist^[0].c2max := MAXJSAMPLE shr C2_SHIFT;
  { Shrink it to actually-used volume and set its statistics }
  update_box(cinfo, boxlist^[0]);
  { Perform median-cut to produce final box list }
  numboxes := median_cut(cinfo, boxlist, numboxes, desired_colors);
  { Compute the representative color for each box, fill colormap }
  for i := 0 to pred(numboxes) do
    compute_color(cinfo, boxlist^[i], i);
  cinfo^.actual_number_of_colors := numboxes;
  {$IFDEF DEBUG}
  TRACEMS1(j_common_ptr(cinfo), 1, JTRC_QUANT_SELECTED, numboxes);
  {$ENDIF}
end;

{ These routines are concerned with the time-critical task of mapping input
  colors to the nearest color in the selected colormap.

  We re-use the histogram space as an "inverse color map", essentially a
  cache for the results of nearest-color searches.  All colors within a
  histogram cell will be mapped to the same colormap entry, namely the one
  closest to the cell's center.  This may not be quite the closest entry to
  the actual input color, but it's almost as good.  A zero in the cache
  indicates we haven't found the nearest color for that cell yet; the array
  is cleared to zeroes before starting the mapping pass.  When we find the
  nearest color for a cell, its colormap index plus one is recorded in the
  cache for future use.  The pass2 scanning routines call fill_inverse_cmap
  when they need to use an unfilled entry in the cache.

  Our method of efficiently finding nearest colors is based on the "locally
  sorted search" idea described by Heckbert and on the incremental distance
  calculation described by Spencer W. Thomas in chapter III.1 of Graphics
  Gems II (James Arvo, ed.  Academic Press, 1991).  Thomas points out that
  the distances from a given colormap entry to each cell of the histogram can
  be computed quickly using an incremental method: the differences between
  distances to adjacent cells themselves differ by a constant.  This allows a
  fairly fast implementation of the "brute force" approach of computing the
  distance from every colormap entry to every histogram cell.  Unfortunately,
  it needs a work array to hold the best-distance-so-far for each histogram
  cell (because the inner loop has to be over cells, not colormap entries).
  The work array elements have to be INT32s, so the work array would need
  256Kb at our recommended precision.  This is not feasible in DOS machines.

  To get around these problems, we apply Thomas' method to compute the
  nearest colors for only the cells within a small subbox of the histogram.
  The work array need be only as big as the subbox, so the memory usage
  problem is solved.  Furthermore, we need not fill subboxes that are never
  referenced in pass2; many images use only part of the color gamut, so a
  fair amount of work is saved.  An additional advantage of this
  approach is that we can apply Heckbert's locality criterion to quickly
  eliminate colormap entries that are far away from the subbox; typically
  three-fourths of the colormap entries are rejected by Heckbert's criterion,
  and we need not compute their distances to individual cells in the subbox.
  The speed of this approach is heavily influenced by the subbox size: too
  small means too much overhead, too big loses because Heckbert's criterion
  can't eliminate as many colormap entries.  Empirically the best subbox
  size seems to be about 1/512th of the histogram (1/8th in each direction).

  Thomas' article also describes a refined method which is asymptotically
  faster than the brute-force method, but it is also far more complex and
  cannot efficiently be applied to small subboxes.  It is therefore not
  useful for programs intended to be portable to DOS machines.  On machines
  with plenty of memory, filling the whole histogram in one shot with Thomas'
  refined method might be faster than the present code --- but then again,
  it might not be any faster, and it's certainly more complicated. }

{ log2(histogram cells in update box) for each axis; this can be adjusted }
const
  BOX_C0_LOG = HIST_C0_BITS - 3;
  BOX_C1_LOG = HIST_C1_BITS - 3;
  BOX_C2_LOG = HIST_C2_BITS - 3;

  BOX_C0_ELEMS = (1 shl BOX_C0_LOG); { # of hist cells in update box }
  BOX_C1_ELEMS = (1 shl BOX_C1_LOG);
  BOX_C2_ELEMS = (1 shl BOX_C2_LOG);

  BOX_C0_SHIFT = (C0_SHIFT + BOX_C0_LOG);
  BOX_C1_SHIFT = (C1_SHIFT + BOX_C1_LOG);
  BOX_C2_SHIFT = (C2_SHIFT + BOX_C2_LOG);

{ The next three routines implement inverse colormap filling.  They could
  all be folded into one big routine, but splitting them up this way saves
  some stack space (the mindist[] and bestdist[] arrays need not coexist)
  and may allow some compilers to produce better code by registerizing more
  inner-loop variables. }

{LOCAL}

//==============================================================================
//
// find_nearby_colors
//
//==============================================================================
function find_nearby_colors(cinfo: j_decompress_ptr; minc0: int;
  minc1: int; minc2: int; var colorlist: array of JSAMPLE): int;
{ Locate the colormap entries close enough to an update box to be candidates
  for the nearest entry to some cell(s) in the update box.  The update box
  is specified by the center coordinates of its first cell.  The number of
  candidate colormap entries is returned, and their colormap indexes are
  placed in colorlist[].
  This routine uses Heckbert's "locally sorted search" criterion to select
  the colors that need further consideration. }

var
  numcolors: int;
  maxc0, maxc1, maxc2: int;
  centerc0, centerc1, centerc2: int;
  i, x, ncolors: int;
  minmaxdist, min_dist, max_dist, tdist: INT32;
  mindist: array[0..MAXNUMCOLORS-1] of INT32;
    { min distance to colormap entry i }
begin
  numcolors := cinfo^.actual_number_of_colors;

  { Compute true coordinates of update box's upper corner and center.
    Actually we compute the coordinates of the center of the upper-corner
    histogram cell, which are the upper bounds of the volume we care about.
    Note that since ">>" rounds down, the "center" values may be closer to
    min than to max; hence comparisons to them must be "<=", not "<". }

  maxc0 := minc0 + ((1 shl BOX_C0_SHIFT) - (1 shl C0_SHIFT));
  centerc0 := (minc0 + maxc0) shr 1;
  maxc1 := minc1 + ((1 shl BOX_C1_SHIFT) - (1 shl C1_SHIFT));
  centerc1 := (minc1 + maxc1) shr 1;
  maxc2 := minc2 + ((1 shl BOX_C2_SHIFT) - (1 shl C2_SHIFT));
  centerc2 := (minc2 + maxc2) shr 1;

  { For each color in colormap, find:
     1. its minimum squared-distance to any point in the update box
        (zero if color is within update box);
     2. its maximum squared-distance to any point in the update box.
    Both of these can be found by considering only the corners of the box.
    We save the minimum distance for each color in mindist[];
    only the smallest maximum distance is of interest. }

  minmaxdist := long($7FFFFFFF);

  for i := 0 to pred(numcolors) do
  begin
    { We compute the squared-c0-distance term, then add in the other two. }
    x := GETJSAMPLE(cinfo^.colormap^[0]^[i]);
    if (x < minc0) then
    begin
      tdist := (x - minc0) * C0_SCALE;
      min_dist := tdist*tdist;
      tdist := (x - maxc0) * C0_SCALE;
      max_dist := tdist*tdist;
    end
    else
      if (x > maxc0) then
      begin
        tdist := (x - maxc0) * C0_SCALE;
        min_dist := tdist*tdist;
        tdist := (x - minc0) * C0_SCALE;
        max_dist := tdist*tdist;
      end
      else
      begin
        { within cell range so no contribution to min_dist }
        min_dist := 0;
        if (x <= centerc0) then
        begin
          tdist := (x - maxc0) * C0_SCALE;
          max_dist := tdist*tdist;
        end
        else
        begin
          tdist := (x - minc0) * C0_SCALE;
          max_dist := tdist*tdist;
        end;
      end;

    x := GETJSAMPLE(cinfo^.colormap^[1]^[i]);
    if (x < minc1) then
    begin
      tdist := (x - minc1) * C1_SCALE;
      inc(min_dist, tdist*tdist);
      tdist := (x - maxc1) * C1_SCALE;
      inc(max_dist, tdist*tdist);
    end
    else
      if (x > maxc1) then
      begin
        tdist := (x - maxc1) * C1_SCALE;
        inc(min_dist, tdist*tdist);
        tdist := (x - minc1) * C1_SCALE;
        inc(max_dist, tdist*tdist);
      end
      else
      begin
        { within cell range so no contribution to min_dist }
        if (x <= centerc1) then
        begin
    tdist := (x - maxc1) * C1_SCALE;
    inc(max_dist, tdist*tdist);
        end
        else
        begin
    tdist := (x - minc1) * C1_SCALE;
    inc(max_dist, tdist*tdist);
        end
      end;

    x := GETJSAMPLE(cinfo^.colormap^[2]^[i]);
    if (x < minc2) then
    begin
      tdist := (x - minc2) * C2_SCALE;
      inc(min_dist, tdist*tdist);
      tdist := (x - maxc2) * C2_SCALE;
      inc(max_dist, tdist*tdist);
    end
    else
      if (x > maxc2) then
      begin
        tdist := (x - maxc2) * C2_SCALE;
        inc(min_dist, tdist*tdist);
        tdist := (x - minc2) * C2_SCALE;
        inc(max_dist, tdist*tdist);
      end
      else
      begin
        { within cell range so no contribution to min_dist }
        if (x <= centerc2) then
        begin
    tdist := (x - maxc2) * C2_SCALE;
    inc(max_dist, tdist*tdist);
        end
        else
        begin
    tdist := (x - minc2) * C2_SCALE;
    inc(max_dist, tdist*tdist);
        end;
      end;

    mindist[i] := min_dist;  { save away the results }
    if (max_dist < minmaxdist) then
      minmaxdist := max_dist;
  end;

  { Now we know that no cell in the update box is more than minmaxdist
    away from some colormap entry.  Therefore, only colors that are
    within minmaxdist of some part of the box need be considered. }

  ncolors := 0;
  for i := 0 to pred(numcolors) do
  begin
    if (mindist[i] <= minmaxdist) then
    begin
      colorlist[ncolors] := JSAMPLE(i);
      inc(ncolors);
    end;
  end;
  find_nearby_colors := ncolors;
end;

{LOCAL}

//==============================================================================
//
// find_best_colors 
//
//==============================================================================
procedure find_best_colors (cinfo: j_decompress_ptr;
                            minc0: int; minc1: int; minc2: int;
                            numcolors: int;
                            var colorlist: array of JSAMPLE;
                            var bestcolor: array of JSAMPLE);
{ Find the closest colormap entry for each cell in the update box,
  given the list of candidate colors prepared by find_nearby_colors.
  Return the indexes of the closest entries in the bestcolor[] array.
  This routine uses Thomas' incremental distance calculation method to
  find the distance from a colormap entry to successive cells in the box. }
const
  { Nominal steps between cell centers ("x" in Thomas article) }
  STEP_C0 = ((1 shl C0_SHIFT) * C0_SCALE);
  STEP_C1 = ((1 shl C1_SHIFT) * C1_SCALE);
  STEP_C2 = ((1 shl C2_SHIFT) * C2_SCALE);
var
  ic0, ic1, ic2: int;
  i, icolor: int;
  {register} bptr: INT32PTR;     { pointer into bestdist[] array }
  cptr: JSAMPLE_PTR;              { pointer into bestcolor[] array }
  dist0, dist1: INT32;         { initial distance values }
  {register} dist2: INT32;  { current distance in inner loop }
  xx0, xx1: INT32;             { distance increments }
  {register} xx2: INT32;
  inc0, inc1, inc2: INT32;  { initial values for increments }
  { This array holds the distance to the nearest-so-far color for each cell }
  bestdist: array[0..BOX_C0_ELEMS * BOX_C1_ELEMS * BOX_C2_ELEMS-1] of INT32;
begin
  { Initialize best-distance for each cell of the update box }
  for i := BOX_C0_ELEMS * BOX_C1_ELEMS*BOX_C2_ELEMS - 1 downto 0 do
    bestdist[i] := $7FFFFFFF;

  { For each color selected by find_nearby_colors,
    compute its distance to the center of each cell in the box.
    If that's less than best-so-far, update best distance and color number. }

  for i := 0 to pred(numcolors) do
  begin
    icolor := GETJSAMPLE(colorlist[i]);
    { Compute (square of) distance from minc0/c1/c2 to this color }
    inc0 := (minc0 - GETJSAMPLE(cinfo^.colormap^[0]^[icolor])) * C0_SCALE;
    dist0 := inc0*inc0;
    inc1 := (minc1 - GETJSAMPLE(cinfo^.colormap^[1]^[icolor])) * C1_SCALE;
    inc(dist0, inc1*inc1);
    inc2 := (minc2 - GETJSAMPLE(cinfo^.colormap^[2]^[icolor])) * C2_SCALE;
    inc(dist0, inc2*inc2);
    { Form the initial difference increments }
    inc0 := inc0 * (2 * STEP_C0) + STEP_C0 * STEP_C0;
    inc1 := inc1 * (2 * STEP_C1) + STEP_C1 * STEP_C1;
    inc2 := inc2 * (2 * STEP_C2) + STEP_C2 * STEP_C2;
    { Now loop over all cells in box, updating distance per Thomas method }
    bptr := @bestdist[0];
    cptr := @bestcolor[0];
    xx0 := inc0;
    for ic0 := BOX_C0_ELEMS - 1 downto 0 do
    begin
      dist1 := dist0;
      xx1 := inc1;
      for ic1 := BOX_C1_ELEMS - 1 downto 0 do
      begin
  dist2 := dist1;
  xx2 := inc2;
  for ic2 := BOX_C2_ELEMS - 1 downto 0 do
        begin
    if (dist2 < bptr^) then
          begin
      bptr^ := dist2;
      cptr^ := JSAMPLE (icolor);
    end;
    inc(dist2, xx2);
    inc(xx2, 2 * STEP_C2 * STEP_C2);
    inc(bptr);
    inc(cptr);
  end;
  inc(dist1, xx1);
  inc(xx1, 2 * STEP_C1 * STEP_C1);
      end;
      inc(dist0, xx0);
      inc(xx0, 2 * STEP_C0 * STEP_C0);
    end;
  end;
end;

{LOCAL}

//==============================================================================
//
// fill_inverse_cmap 
//
//==============================================================================
procedure fill_inverse_cmap (cinfo: j_decompress_ptr;
                             c0: int; c1: int; c2: int);
{ Fill the inverse-colormap entries in the update box that contains }
{ histogram cell c0/c1/c2.  (Only that one cell MUST be filled, but }
{ we can fill as many others as we wish.) }
var
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  minc0, minc1, minc2: int;    { lower left corner of update box }
  ic0, ic1, ic2: int;
  {register} cptr: JSAMPLE_PTR;  { pointer into bestcolor[] array }
  {register} cachep: histptr;  { pointer into main cache array }
  { This array lists the candidate colormap indexes. }
  colorlist: array[0..MAXNUMCOLORS-1] of JSAMPLE;
  numcolors: int;    { number of candidate colors }
  { This array holds the actually closest colormap index for each cell. }
  bestcolor: array[0..BOX_C0_ELEMS * BOX_C1_ELEMS * BOX_C2_ELEMS-1] of JSAMPLE;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);
  histogram := cquantize^.histogram;

  { Convert cell coordinates to update box ID }
  c0 := c0 shr BOX_C0_LOG;
  c1 := c1 shr BOX_C1_LOG;
  c2 := c2 shr BOX_C2_LOG;

  { Compute true coordinates of update box's origin corner.
    Actually we compute the coordinates of the center of the corner
    histogram cell, which are the lower bounds of the volume we care about.}

  minc0 := (c0 shl BOX_C0_SHIFT) + ((1 shl C0_SHIFT) shr 1);
  minc1 := (c1 shl BOX_C1_SHIFT) + ((1 shl C1_SHIFT) shr 1);
  minc2 := (c2 shl BOX_C2_SHIFT) + ((1 shl C2_SHIFT) shr 1);

  { Determine which colormap entries are close enough to be candidates
    for the nearest entry to some cell in the update box. }

  numcolors := find_nearby_colors(cinfo, minc0, minc1, minc2, colorlist);

  { Determine the actually nearest colors. }
  find_best_colors(cinfo, minc0, minc1, minc2, numcolors, colorlist,
       bestcolor);

  { Save the best color numbers (plus 1) in the main cache array }
  c0 := c0 shl BOX_C0_LOG;    { convert ID back to base cell indexes }
  c1 := c1 shl BOX_C1_LOG;
  c2 := c2 shl BOX_C2_LOG;
  cptr := @(bestcolor[0]);
  for ic0 := 0 to pred(BOX_C0_ELEMS) do
    for ic1 := 0 to pred(BOX_C1_ELEMS) do
    begin
      cachep := @(histogram^[c0+ic0]^[c1+ic1][c2]);
      for ic2 := 0 to pred(BOX_C2_ELEMS) do
      begin
  cachep^ := histcell (GETJSAMPLE(cptr^) + 1);
        inc(cachep);
        inc(cptr);
      end;
    end;
end;

{ Map some rows of pixels to the output colormapped representation. }

{METHODDEF}

//==============================================================================
//
// pass2_no_dither 
//
//==============================================================================
procedure pass2_no_dither (cinfo: j_decompress_ptr;
               input_buf: JSAMPARRAY;
                           output_buf: JSAMPARRAY;
                           num_rows: int); far;
{ This version performs no dithering }
var
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  {register} inptr: RGBptr;
             outptr: JSAMPLE_PTR;
  {register} cachep: histptr;
  {register} c0, c1, c2: int;
  row: int;
  col: JDIMENSION;
  width: JDIMENSION;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);
  histogram := cquantize^.histogram;
  width := cinfo^.output_width;

  for row := 0 to pred(num_rows) do
  begin
    inptr := RGBptr(input_buf^[row]);
    outptr := JSAMPLE_PTR(output_buf^[row]);
    for col := pred(width) downto 0 do
    begin
      { get pixel value and index into the cache }
      c0 := GETJSAMPLE(inptr^.r) shr C0_SHIFT;
      c1 := GETJSAMPLE(inptr^.g) shr C1_SHIFT;
      c2 := GETJSAMPLE(inptr^.b) shr C2_SHIFT;
      inc(inptr);
      cachep := @(histogram^[c0]^[c1][c2]);
      { If we have not seen this color before, find nearest colormap entry }
      { and update the cache }
      if (cachep^ = 0) then
  fill_inverse_cmap(cinfo, c0,c1,c2);
      { Now emit the colormap index for this cell }
      outptr^ := JSAMPLE (cachep^ - 1);
      inc(outptr);
    end;
  end;
end;

{METHODDEF}

//==============================================================================
//
// pass2_fs_dither 
//
//==============================================================================
procedure pass2_fs_dither (cinfo: j_decompress_ptr;
               input_buf: JSAMPARRAY;
                           output_buf: JSAMPARRAY;
                           num_rows: int); far;
{ This version performs Floyd-Steinberg dithering }
var
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  {register} cur: LOCRGB_FSERROR;  { current error or pixel value }
  belowerr: LOCRGB_FSERROR; { error for pixel below cur }
  bpreverr: LOCRGB_FSERROR; { error for below/prev col }
  prev_errorptr,
  {register} errorptr: RGB_FSERROR_PTR;  { => fserrors[] at column before current }
  inptr: RGBptr;    { => current input pixel }
  outptr: JSAMPLE_PTR;    { => current output pixel }
  cachep: histptr;
  dir: int;      { +1 or -1 depending on direction }
  row: int;
  col: JDIMENSION;
  width: JDIMENSION;
  range_limit: range_limit_table_ptr;
  error_limit: error_limit_ptr;
  colormap0: JSAMPROW;
  colormap1: JSAMPROW;
  colormap2: JSAMPROW;
  {register} pixcode: int;
  {register} bnexterr, delta: LOCFSERROR;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);
  histogram := cquantize^.histogram;
  width := cinfo^.output_width;
  range_limit := cinfo^.sample_range_limit;
  error_limit := cquantize^.error_limiter;
  colormap0 := cinfo^.colormap^[0];
  colormap1 := cinfo^.colormap^[1];
  colormap2 := cinfo^.colormap^[2];

  for row := 0 to pred(num_rows) do
  begin
    inptr := RGBptr(input_buf^[row]);
    outptr := JSAMPLE_PTR(output_buf^[row]);
    errorptr := RGB_FSERROR_PTR(cquantize^.fserrors); { => entry before first real column }
    if (cquantize^.on_odd_row) then
    begin
      { work right to left in this row }
      inc(inptr, (width-1));     { so point to rightmost pixel }
      inc(outptr, width-1);
      dir := -1;
      inc(errorptr, (width+1)); { => entry after last column }
      cquantize^.on_odd_row := FALSE; { flip for next time }
    end
    else
    begin
      { work left to right in this row }
      dir := 1;
      cquantize^.on_odd_row := TRUE; { flip for next time }
    end;

    { Preset error values: no error propagated to first pixel from left }
    cur.r := 0;
    cur.g := 0;
    cur.b := 0;
    { and no error propagated to row below yet }
    belowerr.r := 0;
    belowerr.g := 0;
    belowerr.b := 0;
    bpreverr.r := 0;
    bpreverr.g := 0;
    bpreverr.b := 0;

    for col := pred(width) downto 0 do
    begin
      prev_errorptr := errorptr;
      inc(errorptr, dir);  { advance errorptr to current column }

      { curN holds the error propagated from the previous pixel on the
        current line.  Add the error propagated from the previous line
        to form the complete error correction term for this pixel, and
        round the error term (which is expressed * 16) to an integer.
        RIGHT_SHIFT rounds towards minus infinity, so adding 8 is correct
        for either sign of the error value.
        Note: prev_errorptr points to *previous* column's array entry. }

      { Nomssi Note: Borland Pascal SHR is unsigned }
      cur.r := (cur.r + errorptr^.r + 8) div 16;
      cur.g := (cur.g + errorptr^.g + 8) div 16;
      cur.b := (cur.b + errorptr^.b + 8) div 16;
      { Limit the error using transfer function set by init_error_limit.
        See comments with init_error_limit for rationale. }

      cur.r := error_limit^[cur.r];
      cur.g := error_limit^[cur.g];
      cur.b := error_limit^[cur.b];
      { Form pixel value + error, and range-limit to 0..MAXJSAMPLE.
        The maximum error is +- MAXJSAMPLE (or less with error limiting);
        this sets the required size of the range_limit array. }

      inc(cur.r, GETJSAMPLE(inptr^.r));
      inc(cur.g, GETJSAMPLE(inptr^.g));
      inc(cur.b, GETJSAMPLE(inptr^.b));

      cur.r := GETJSAMPLE(range_limit^[cur.r]);
      cur.g := GETJSAMPLE(range_limit^[cur.g]);
      cur.b := GETJSAMPLE(range_limit^[cur.b]);
      { Index into the cache with adjusted pixel value }
      cachep := @(histogram^[cur.r shr C0_SHIFT]^
                            [cur.g shr C1_SHIFT][cur.b shr C2_SHIFT]);
      { If we have not seen this color before, find nearest colormap }
      { entry and update the cache }
      if (cachep^ = 0) then
  fill_inverse_cmap(cinfo, cur.r shr C0_SHIFT,
                                 cur.g shr C1_SHIFT,
                                 cur.b shr C2_SHIFT);
      { Now emit the colormap index for this cell }

      pixcode := cachep^ - 1;
      outptr^ := JSAMPLE (pixcode);

      { Compute representation error for this pixel }
      dec(cur.r, GETJSAMPLE(colormap0^[pixcode]));
      dec(cur.g, GETJSAMPLE(colormap1^[pixcode]));
      dec(cur.b, GETJSAMPLE(colormap2^[pixcode]));

      { Compute error fractions to be propagated to adjacent pixels.
        Add these into the running sums, and simultaneously shift the
        next-line error sums left by 1 column. }

      bnexterr := cur.r;  { Process component 0 }
      delta := cur.r * 2;
      inc(cur.r, delta);    { form error * 3 }
      prev_errorptr^.r := FSERROR (bpreverr.r + cur.r);
      inc(cur.r, delta);    { form error * 5 }
      bpreverr.r := belowerr.r + cur.r;
      belowerr.r := bnexterr;
      inc(cur.r, delta);    { form error * 7 }
      bnexterr := cur.g;  { Process component 1 }
      delta := cur.g * 2;
      inc(cur.g, delta);    { form error * 3 }
      prev_errorptr^.g := FSERROR (bpreverr.g + cur.g);
      inc(cur.g, delta);    { form error * 5 }
      bpreverr.g := belowerr.g + cur.g;
      belowerr.g := bnexterr;
      inc(cur.g, delta);    { form error * 7 }
      bnexterr := cur.b;  { Process component 2 }
      delta := cur.b * 2;
      inc(cur.b, delta);    { form error * 3 }
      prev_errorptr^.b := FSERROR (bpreverr.b + cur.b);
      inc(cur.b, delta);    { form error * 5 }
      bpreverr.b := belowerr.b + cur.b;
      belowerr.b := bnexterr;
      inc(cur.b, delta);    { form error * 7 }

      { At this point curN contains the 7/16 error value to be propagated
        to the next pixel on the current line, and all the errors for the
        next line have been shifted over.  We are therefore ready to move on.}

      inc(inptr, dir);    { Advance pixel pointers to next column }
      inc(outptr, dir);
    end;
    { Post-loop cleanup: we must unload the final error values into the
      final fserrors[] entry.  Note we need not unload belowerrN because
      it is for the dummy column before or after the actual array. }

    errorptr^.r := FSERROR (bpreverr.r); { unload prev errs into array }
    errorptr^.g := FSERROR (bpreverr.g);
    errorptr^.b := FSERROR (bpreverr.b);
  end;
end;

{ Initialize the error-limiting transfer function (lookup table).
  The raw F-S error computation can potentially compute error values of up to
  +- MAXJSAMPLE.  But we want the maximum correction applied to a pixel to be
  much less, otherwise obviously wrong pixels will be created.  (Typical
  effects include weird fringes at color-area boundaries, isolated bright
  pixels in a dark area, etc.)  The standard advice for avoiding this problem
  is to ensure that the "corners" of the color cube are allocated as output
  colors; then repeated errors in the same direction cannot cause cascading
  error buildup.  However, that only prevents the error from getting
  completely out of hand; Aaron Giles reports that error limiting improves
  the results even with corner colors allocated.
  A simple clamping of the error values to about +- MAXJSAMPLE/8 works pretty
  well, but the smoother transfer function used below is even better.  Thanks
  to Aaron Giles for this idea. }

{LOCAL}

//==============================================================================
//
// init_error_limit 
//
//==============================================================================
procedure init_error_limit (cinfo: j_decompress_ptr);
const
  STEPSIZE = ((MAXJSAMPLE+1) div 16);
{ Allocate and fill in the error_limiter table }
var
  cquantize: my_cquantize_ptr;
  table: error_limit_ptr;
  inp, out: int;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);
  table := error_limit_ptr (cinfo^.mem^.alloc_small
    (j_common_ptr (cinfo), JPOOL_IMAGE, (MAXJSAMPLE*2+1) * SizeOf(int)));
  { not needed: inc(table, MAXJSAMPLE);
                so can index -MAXJSAMPLE .. +MAXJSAMPLE }
  cquantize^.error_limiter := table;
  { Map errors 1:1 up to +- MAXJSAMPLE/16 }
  out := 0;
  for inp := 0 to pred(STEPSIZE) do
  begin
    table^[inp] := out;
    table^[-inp] := -out;
    inc(out);
  end;
  { Map errors 1:2 up to +- 3*MAXJSAMPLE/16 }
  inp := STEPSIZE;       { Nomssi: avoid problems with Delphi2 optimizer }
  while (inp < STEPSIZE*3) do
  begin
    table^[inp] := out;
    table^[-inp] := -out;
    inc(inp);
    if Odd(inp) then
      inc(out);
  end;
  { Clamp the rest to final out value (which is (MAXJSAMPLE+1)/8) }
  inp := STEPSIZE*3;     { Nomssi: avoid problems with Delphi 2 optimizer }
  while inp <= MAXJSAMPLE do
  begin
    table^[inp] := out;
    table^[-inp] := -out;
    inc(inp);
  end;
end;

{ Finish up at the end of each pass. }

{METHODDEF}

//==============================================================================
//
// finish_pass1 
//
//==============================================================================
procedure finish_pass1 (cinfo: j_decompress_ptr); far;
var
  cquantize: my_cquantize_ptr;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);

  { Select the representative colors and fill in cinfo^.colormap }
  cinfo^.colormap := cquantize^.sv_colormap;
  select_colors(cinfo, cquantize^.desired);
  { Force next pass to zero the color index table }
  cquantize^.needs_zeroed := TRUE;
end;

{METHODDEF}

//==============================================================================
//
// finish_pass2 
//
//==============================================================================
procedure finish_pass2 (cinfo: j_decompress_ptr); far;
begin
  { no work }
end;

{ Initialize for each processing pass. }

{METHODDEF}

//==============================================================================
//
// start_pass_2_quant 
//
//==============================================================================
procedure start_pass_2_quant (cinfo: j_decompress_ptr;
                              is_pre_scan: boolean); far;
var
  cquantize: my_cquantize_ptr;
  histogram: hist3d;
  i: int;
var
  arraysize: size_t;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);
  histogram := cquantize^.histogram;
  { Only F-S dithering or no dithering is supported. }
  { If user asks for ordered dither, give him F-S. }
  if (cinfo^.dither_mode <> JDITHER_NONE) then
    cinfo^.dither_mode := JDITHER_FS;

  if (is_pre_scan) then
  begin
    { Set up method pointers }
    cquantize^.pub.color_quantize := prescan_quantize;
    cquantize^.pub.finish_pass := finish_pass1;
    cquantize^.needs_zeroed := TRUE; { Always zero histogram }
  end
  else
  begin
    { Set up method pointers }
    if (cinfo^.dither_mode = JDITHER_FS) then
      cquantize^.pub.color_quantize := pass2_fs_dither
    else
      cquantize^.pub.color_quantize := pass2_no_dither;
    cquantize^.pub.finish_pass := finish_pass2;

    { Make sure color count is acceptable }
    i := cinfo^.actual_number_of_colors;
    if (i < 1) then
      ERREXIT1(j_common_ptr(cinfo), JERR_QUANT_FEW_COLORS, 1);
    if (i > MAXNUMCOLORS) then
      ERREXIT1(j_common_ptr(cinfo), JERR_QUANT_MANY_COLORS, MAXNUMCOLORS);

    if (cinfo^.dither_mode = JDITHER_FS) then
    begin
      arraysize := size_t ((cinfo^.output_width + 2) *
           (3 * SizeOf(FSERROR)));
      { Allocate Floyd-Steinberg workspace if we didn't already. }
      if (cquantize^.fserrors = nil) then
  cquantize^.fserrors := FS_ERROR_FIELD_PTR (cinfo^.mem^.alloc_large
    (j_common_ptr(cinfo), JPOOL_IMAGE, arraysize));
      { Initialize the propagated errors to zero. }
      jzero_far(cquantize^.fserrors, arraysize);
      { Make the error-limit table if we didn't already. }
      if (cquantize^.error_limiter = nil) then
  init_error_limit(cinfo);
      cquantize^.on_odd_row := FALSE;
    end;

  end;
  { Zero the histogram or inverse color map, if necessary }
  if (cquantize^.needs_zeroed) then
  begin
    for i := 0 to pred(HIST_C0_ELEMS) do
    begin
      jzero_far( histogram^[i],
    HIST_C1_ELEMS*HIST_C2_ELEMS * SizeOf(histcell));
    end;
    cquantize^.needs_zeroed := FALSE;
  end;
end;

{ Switch to a new external colormap between output passes. }

{METHODDEF}

//==============================================================================
//
// new_color_map_2_quant 
//
//==============================================================================
procedure new_color_map_2_quant (cinfo: j_decompress_ptr); far;
var
  cquantize: my_cquantize_ptr;
begin
  cquantize := my_cquantize_ptr (cinfo^.cquantize);

  { Reset the inverse color map }
  cquantize^.needs_zeroed := TRUE;
end;

{ Module initialization routine for 2-pass color quantization. }

{GLOBAL}

//==============================================================================
//
// jinit_2pass_quantizer 
//
//==============================================================================
procedure jinit_2pass_quantizer (cinfo: j_decompress_ptr);
var
  cquantize: my_cquantize_ptr;
  i: int;
var
  desired: int;
begin
  cquantize := my_cquantize_ptr(
    cinfo^.mem^.alloc_small (j_common_ptr(cinfo), JPOOL_IMAGE,
        SizeOf(my_cquantizer)));
  cinfo^.cquantize := jpeg_color_quantizer_ptr(cquantize);
  cquantize^.pub.start_pass := start_pass_2_quant;
  cquantize^.pub.new_color_map := new_color_map_2_quant;
  cquantize^.fserrors := nil;  { flag optional arrays not allocated }
  cquantize^.error_limiter := nil;

  { Make sure jdmaster didn't give me a case I can't handle }
  if (cinfo^.out_color_components <> 3) then
    ERREXIT(j_common_ptr(cinfo), JERR_NOTIMPL);

  { Allocate the histogram/inverse colormap storage }
  cquantize^.histogram := hist3d (cinfo^.mem^.alloc_small
    (j_common_ptr (cinfo), JPOOL_IMAGE, HIST_C0_ELEMS * SizeOf(hist2d)));
  for i := 0 to pred(HIST_C0_ELEMS) do
  begin
    cquantize^.histogram^[i] := hist2d (cinfo^.mem^.alloc_large
      (j_common_ptr (cinfo), JPOOL_IMAGE,
       HIST_C1_ELEMS*HIST_C2_ELEMS * SizeOf(histcell)));
  end;
  cquantize^.needs_zeroed := TRUE; { histogram is garbage now }

  { Allocate storage for the completed colormap, if required.
    We do this now since it is FAR storage and may affect
    the memory manager's space calculations. }

  if (cinfo^.enable_2pass_quant) then
  begin
    { Make sure color count is acceptable }
    desired := cinfo^.desired_number_of_colors;
    { Lower bound on # of colors ... somewhat arbitrary as long as > 0 }
    if (desired < 8) then
      ERREXIT1(j_common_ptr (cinfo), JERR_QUANT_FEW_COLORS, 8);
    { Make sure colormap indexes can be represented by JSAMPLEs }
    if (desired > MAXNUMCOLORS) then
      ERREXIT1(j_common_ptr (cinfo), JERR_QUANT_MANY_COLORS, MAXNUMCOLORS);
    cquantize^.sv_colormap := cinfo^.mem^.alloc_sarray
      (j_common_ptr (cinfo),JPOOL_IMAGE, JDIMENSION(desired), JDIMENSION(3));
    cquantize^.desired := desired;
  end
  else
    cquantize^.sv_colormap := nil;

  { Only F-S dithering or no dithering is supported. }
  { If user asks for ordered dither, give him F-S. }
  if (cinfo^.dither_mode <> JDITHER_NONE) then
    cinfo^.dither_mode := JDITHER_FS;

  { Allocate Floyd-Steinberg workspace if necessary.
    This isn't really needed until pass 2, but again it is FAR storage.
    Although we will cope with a later change in dither_mode,
    we do not promise to honor max_memory_to_use if dither_mode changes. }

  if (cinfo^.dither_mode = JDITHER_FS) then
  begin
    cquantize^.fserrors := FS_ERROR_FIELD_PTR (cinfo^.mem^.alloc_large
      (j_common_ptr(cinfo), JPOOL_IMAGE,
       size_t ((cinfo^.output_width + 2) * (3 * SizeOf(FSERROR))) ) );
    { Might as well create the error-limiting table too. }
    init_error_limit(cinfo);
  end;
end;
     { QUANT_2PASS_SUPPORTED }
end.
