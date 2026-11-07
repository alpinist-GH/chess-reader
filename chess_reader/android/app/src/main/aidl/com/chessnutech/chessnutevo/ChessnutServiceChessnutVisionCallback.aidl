// ChessnutServiceChessnutVisionCallback.aidl
package com.chessnutech.chessnutevo;

interface ChessnutServiceChessnutVisionCallback {
/*
   valid: if one and only chessboard is detected from the bitmap;
   x,y,w: x[0],y[0],w[0] indicate the left-up corner coordinate of the chessboard, and the width of the squares;
          x[1],y[1],w[1] promotion of queen square coordinate;
          x[2],y[2],w[2] promotion of knight square coordinate;
          x[3],y[3],w[3] promotion of rook square coordinate;
          x[4],y[4],w[4] promotion of bishop square coordinate;
   promote: if the promotion state is detected, if true x,y,w[1..4] is valid;
   fen: the fen string of the chessboard, if not blank x,y,w[0] is valid;
   stars: the index of the stars detected on the chessboard
*/
    oneway void onDetectionResult(in boolean valid, in float[] x, in float[] y, in float[] w, in boolean promote, in String fen, in int[] stars);
}
